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
const pattern_mod = @import("../dsp/pattern.zig");

pub const spectrum_rows: usize = 18;
pub const spectrum_band_count: usize = 80;
/// Number of editable synth parameters.
/// OSC A : 0:waveform 1:pulse_width 2:detune 3:unison 4:uni.det 5:uni.spread
/// OSC B : 6:b_on 7:b_waveform 8:b_pw 9:b_semi 10:b_detune 11:b_level 12:b_unison 13:b_uni.det
/// MOD   : 14:mod_mode 15:mod_amount
/// ENV   : 16:attack 17:decay 18:sustain 19:release
/// FILTER: 20:filter_type 21:cutoff 22:res 23:fenv_amount
/// FENV  : 24:fenv_attack 25:fenv_decay 26:fenv_sustain 27:fenv_release
/// LFO   : 28:lfo_shape 29:lfo_rate 30:lfo_depth 31:lfo_target
/// VOICE : 32:voice_mode 33:glide
/// SUB   : 34:sub_level 35:sub_shape
/// NOISE : 36:noise_level 37:noise_color
/// OUT   : 38:gain
pub const synth_param_count: u8 = 39;

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
    try w.writeAll(dim ++ "   [enter:edit  p:piano  s:spectrum  m:mute  M:master  a:add  D:del  ?:help]");
    try endLine(w);

    for (app.project.tracks.items, 0..) |track, i| {
        const is_drum = (i == app.drum_track);
        const label: []const u8 = if (is_drum) "drum machine" else app.racks.items[i].label;
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
        // FX badges
        if (!is_drum and i < app.racks.items.len) {
            const rfx = app.racks.items[i].fx;
            const any = rfx.comp != null or rfx.eq != null or rfx.delay != null or rfx.reverb != null;
            if (any) {
                if (!is_sel and !faded) try w.writeAll(acc);
                if (rfx.comp   != null) try w.writeAll(" cmp");
                if (rfx.eq     != null) try w.writeAll(" eq");
                if (rfx.delay  != null) try w.writeAll(" dly");
                if (rfx.reverb != null) try w.writeAll(" rev");
                if (!is_sel and !faded) try w.writeAll(rst);
            }
        }
        // Gain / pan — always shown; dim at defaults, accented when non-default.
        {
            const gdb = track.gain_db;
            const pan = track.pan;
            // gain
            if (gdb == 0.0) {
                if (!is_sel and !faded) try w.writeAll(dim);
                try w.writeAll("  0dB");
                if (!is_sel and !faded) try w.writeAll(rst);
            } else {
                const sign: []const u8 = if (gdb >= 0.0) "+" else "";
                try w.print("  {s}{d:.0}dB", .{ sign, gdb });
            }
            // pan
            if (pan == 0.0) {
                if (!is_sel and !faded) try w.writeAll(dim);
                try w.writeAll("  C");
                if (!is_sel and !faded) try w.writeAll(rst);
            } else {
                const pct: i32 = @intFromFloat(@abs(pan) * 100.0);
                try w.print("  {s}{d}%", .{ if (pan < 0.0) "L" else "R", pct });
            }
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
    try w.writeAll(dim ++ "  [hjkl:move  spc:toggle  p:preview  <>:length  X:clear  F:fill  esc:back]");
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
    try helpKey(w, "[ / ]",        "master volume down / up  (except piano roll)");
    try helpKey(w, "space",        "play / pause");
    try helpKey(w, "gg",           "rewind to start");
    try helpKey(w, "i",            "enter INSERT mode (play notes)");
    try helpKey(w, "esc",          "back / return to NORMAL mode");
    try helpKey(w, ":",            "open command prompt");
    try helpKey(w, "ctrl-c",       "quit");

    try helpSection(w, "TRACKS");
    try helpKey(w, "j / k",        "move cursor down / up");
    try helpKey(w, "enter",        "edit track (synth or drum grid)");
    try helpKey(w, "p",            "piano roll for synth tracks");
    try helpKey(w, "s",            "spectrum + EQ for selected track");
    try helpKey(w, "m",            "mute / unmute selected track");
    try helpKey(w, "M",            "master spectrum");
    try helpKey(w, "< / >",        "pan left / right  (5% per step)");
    try helpKey(w, "- / =",        "track gain −1 dB / +1 dB");
    try helpKey(w, "a",            "add synth track");
    try helpKey(w, "D",            "delete selected track");
    try helpKey(w, "? / :help",    "this help");

    try helpSection(w, "INSERT MODE  (piano keyboard)");
    try helpKey(w, "a s d f g h j k l ;",  "white keys  C D E F G A B C D E");
    try helpKey(w, "q w r t y i o p",       "black keys  C# D# F# G# A# C# D# F#");
    try helpKey(w, "z / x",                 "octave down / up");

    try helpSection(w, "DRUM GRID");
    try helpKey(w, "h / j / k / l","move cursor left/down/up/right");
    try helpKey(w, "enter",        "toggle step on/off");
    try helpKey(w, "p",            "preview pad sound");
    try helpKey(w, "s",            "spectrum + EQ for drum track");
    try helpKey(w, "< / >",        "shorten / lengthen loop (1–16 steps)");
    try helpKey(w, "X",            "clear all steps on current pad");
    try helpKey(w, "F",            "fill all steps on current pad");

    try helpSection(w, "SYNTH EDITOR");
    try helpKey(w, "j / k",        "select parameter");
    try helpKey(w, "{ / }",        "prev / next section");
    try helpKey(w, "h / l",        "adjust value (fine)");
    try helpKey(w, "H / L",        "adjust value (coarse ×10)");
    try helpKey(w, "s",            "spectrum + EQ for this track");

    try helpSection(w, "PIANO ROLL");
    try helpKey(w, "h / j / k / l","move cursor left/down/up/right");
    try helpKey(w, "n",            "insert note at cursor");
    try helpKey(w, "d",            "delete note at cursor");
    try helpKey(w, "e",            "open synth editor for this track");
    try helpKey(w, "s",            "spectrum + EQ for this track");
    try helpKey(w, "[ / ]",        "decrease / increase note length");
    try helpKey(w, "+ / -",        "add / remove 1 bar from loop");

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

/// Render the full 51-row synth editor into `w`, applying vertical scroll so
/// it fits within `max_rows`. Always shows the title line, then slices the
/// parameter body to keep the cursor in view.
pub fn drawSynthEditor(app: anytype, w: *std.Io.Writer, rows: usize, snap: engine_mod.UiSnapshot) !void {
    // Available rows for the view body (excludes outer header+hr + transport+hr+status).
    const max_rows = rows -| 5;
    // Clamp scroll so cursor row is visible.
    const cursor_row = @import("../tui/app.zig").App.synthParamRow(app.synth_cursor);
    var scroll = app.synth_scroll;
    if (cursor_row < scroll) scroll = cursor_row;
    if (cursor_row >= scroll + max_rows) scroll = cursor_row -| max_rows + 1;

    // Render full editor into a temp buffer, then slice visible rows.
    var tmp: [16 * 1024]u8 = undefined;
    var tw = std.Io.Writer.fixed(&tmp);
    try drawSynthEditorFull(app, &tw, snap);

    // The full output uses \r\n line endings (from endLine). Split and emit
    // only rows [scroll, scroll+max_rows).
    const full = tw.buffered();
    var line_it = std.mem.splitSequence(u8, full, "\r\n");
    var row: usize = 0;
    var written: usize = 0;
    // Always emit the title line (row 0) first, outside the scroll window.
    if (line_it.next()) |title| {
        try w.writeAll(title);
        try w.writeAll("\r\n");
        written += 1;
        row += 1;
    }
    while (line_it.next()) |line| : (row += 1) {
        if (written >= max_rows) break;
        if (row < scroll + 1) continue; // +1 because title was row 0
        try w.writeAll(line);
        try w.writeAll("\r\n");
        written += 1;
    }
    while (written < max_rows) : (written += 1) try endLine(w);
    // used: outer header(1)+hr(1) are already counted; view writes max_rows rows.
    // Padding: none needed — we already filled exactly max_rows.
}

fn drawSynthEditorFull(app: anytype, w: *std.Io.Writer, snap: engine_mod.UiSnapshot) !void {
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
    try w.writeAll(dim ++ "  [jk:move  hl:adjust  HL:coarse  {}:section  esc:back]");
    try endLine(w);

    // ── OSC ──────────────────────────────────────
    try synthSection(w, "OSC");

    // param 0: waveform
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

    // param 1: pulse width (only meaningful for square)
    {
        const is_sel = (app.synth_cursor == 1);
        if (is_sel) try w.writeAll(sel);
        const active_sqr = synth.waveform == .square;
        if (!is_sel and !active_sqr) try w.writeAll(dim);
        try w.writeAll("  pls.width ");
        try synthBar(w, synth.pulse_width, 1.0);
        try w.print("  {d:.2}", .{synth.pulse_width});
        if (!is_sel and !active_sqr) try w.writeAll(rst);
        try endLine(w);
    }

    // params 2–5: detune, unison, uni.det, spread
    const osc_rows = [_]struct { label: []const u8, idx: u8, bar: f32, bar_max: f32, disp: f32 }{
        .{ .label = "detune",   .idx = 2, .bar = synth.detune_cents + 100.0, .bar_max = 200.0, .disp = synth.detune_cents   },
        .{ .label = "unison",   .idx = 3, .bar = @floatFromInt(synth.unison),.bar_max = 16.0,  .disp = @floatFromInt(synth.unison) },
        .{ .label = "uni.det",  .idx = 4, .bar = synth.unison_detune,        .bar_max = 100.0, .disp = synth.unison_detune  },
        .{ .label = "spread",   .idx = 5, .bar = synth.unison_spread,        .bar_max = 1.0,   .disp = synth.unison_spread  },
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
            3 => try w.print("  {d:.2}",    .{p.disp}),
            else => {},
        }
        try endLine(w);
    }

    // ── OSC B ────────────────────────────────────
    try synthSection(w, "OSC B");

    // param 6: osc_b_on (b_on moved to 6, was 5)
    {
        const is_sel = (app.synth_cursor == 6);
        if (is_sel) try w.writeAll(sel);
        const active = synth.osc_b_on;
        if (!is_sel and !active) try w.writeAll(dim);
        try w.writeAll("  on/off     ");
        if (active) {
            if (!is_sel) try w.writeAll(acc ++ bold);
            try w.writeAll("[on  ]  off  ");
            if (!is_sel) try w.writeAll(rst);
        } else {
            try w.writeAll(" on    [off ]");
        }
        if (!is_sel and !active) try w.writeAll(rst);
        try endLine(w);
    }

    // param 7: osc_b_waveform
    {
        const is_sel  = (app.synth_cursor == 7);
        const b_active = synth.osc_b_on;
        if (is_sel) try w.writeAll(sel);
        if (!is_sel and !b_active) try w.writeAll(dim);
        try w.writeAll("  waveform   ");
        const wf_names = [_][]const u8{ "sine", "saw", "tri", "sqr" };
        const wf_idx: usize = switch (synth.osc_b_waveform) {
            .sine => 0, .saw => 1, .triangle => 2, .square => 3,
        };
        for (wf_names, 0..) |nm, i| {
            if (i == wf_idx) {
                if (!is_sel and b_active) try w.writeAll(acc ++ bold);
                try w.print("[{s: <5}]", .{nm});
                if (!is_sel and b_active) try w.writeAll(rst);
            } else {
                try w.print(" {s: <5} ", .{nm});
            }
        }
        if (!is_sel and !b_active) try w.writeAll(rst);
        try endLine(w);
    }

    // params 8–13: pulse width, semi, detune, level, unison, uni.det
    {
        const b_rows = [_]struct { label: []const u8, idx: u8, bar: f32, bar_max: f32, disp: f32, fmt: u8 }{
            .{ .label = "pls.width", .idx = 8,  .bar = synth.osc_b_pulse_width,           .bar_max = 1.0,   .disp = synth.osc_b_pulse_width,  .fmt = 2 },
            .{ .label = "semi",      .idx = 9,  .bar = synth.osc_b_semi + 24.0,           .bar_max = 48.0,  .disp = synth.osc_b_semi,         .fmt = 0 },
            .{ .label = "detune",    .idx = 10, .bar = synth.osc_b_detune_cents + 100.0,  .bar_max = 200.0, .disp = synth.osc_b_detune_cents, .fmt = 1 },
            .{ .label = "level",     .idx = 11, .bar = synth.osc_b_level,                 .bar_max = 1.0,   .disp = synth.osc_b_level,        .fmt = 2 },
            .{ .label = "unison",    .idx = 12, .bar = @floatFromInt(synth.osc_b_unison), .bar_max = 16.0,  .disp = @floatFromInt(synth.osc_b_unison), .fmt = 0 },
            .{ .label = "uni.det",   .idx = 13, .bar = synth.osc_b_unison_detune,        .bar_max = 100.0, .disp = synth.osc_b_unison_detune, .fmt = 3 },
        };
        for (b_rows) |p| {
            const is_sel  = (app.synth_cursor == p.idx);
            const b_active = synth.osc_b_on;
            if (is_sel) try w.writeAll(sel);
            if (!is_sel and !b_active) try w.writeAll(dim);
            try w.print("  {s: <9}", .{p.label});
            try synthBar(w, p.bar, p.bar_max);
            switch (p.fmt) {
                0 => try w.print("  {d:.0}", .{p.disp}),
                1 => try w.print("  {d:.0} ct", .{p.disp}),
                2 => try w.print("  {d:.2}", .{p.disp}),
                3 => try w.print("  {d:.1} ct", .{p.disp}),
                else => {},
            }
            if (!is_sel and !b_active) try w.writeAll(rst);
            try endLine(w);
        }
    }

    // ── MOD ──────────────────────────────────────
    try synthSection(w, "MOD  (A \u{2194} B)");

    // param 14: mod_mode
    {
        const is_sel = (app.synth_cursor == 14);
        const active = synth.mod_mode != .none;
        if (is_sel) try w.writeAll(sel);
        if (!is_sel and !active) try w.writeAll(dim);
        try w.writeAll("  mode       ");
        const mod_names = [_][]const u8{ "off", "ring", "AM>B", "AM>A", "FM>B", "FM>A" };
        const mod_idx: usize = switch (synth.mod_mode) {
            .none => 0, .ring => 1, .am_a_to_b => 2, .am_b_to_a => 3,
            .fm_a_to_b => 4, .fm_b_to_a => 5,
        };
        for (mod_names, 0..) |nm, i| {
            if (i == mod_idx) {
                if (!is_sel) try w.writeAll(acc ++ bold);
                try w.print("[{s: <5}]", .{nm});
                if (!is_sel) try w.writeAll(rst);
            } else {
                if (!is_sel) try w.writeAll(dim);
                try w.print(" {s: <5} ", .{nm});
                if (!is_sel) try w.writeAll(rst);
            }
        }
        if (!is_sel and !active) try w.writeAll(rst);
        try endLine(w);
    }

    // param 15: mod_amount
    {
        const is_sel = (app.synth_cursor == 15);
        const active = synth.mod_mode != .none;
        if (is_sel) try w.writeAll(sel);
        if (!is_sel and !active) try w.writeAll(dim);
        try w.writeAll("  amount   ");
        // FM max is 8; AM/ring max is 1 — display bar against max=8 but show actual value.
        try synthBar(w, synth.mod_amount, 8.0);
        const unit: []const u8 = switch (synth.mod_mode) {
            .fm_a_to_b, .fm_b_to_a => "  β=",
            else                    => "    ",
        };
        try w.print("{s}{d:.2}", .{ unit, synth.mod_amount });
        if (!is_sel and !active) try w.writeAll(rst);
        try endLine(w);
    }

    // ── ENV ──────────────────────────────────────
    try synthSection(w, "ENV");

    const env_rows = [_]struct { label: []const u8, idx: u8, bar: f32, bar_max: f32, disp: f32 }{
        .{ .label = "attack",  .idx = 16, .bar = synth.attack_s,  .bar_max = 5.0,  .disp = synth.attack_s  },
        .{ .label = "decay",   .idx = 17, .bar = synth.decay_s,   .bar_max = 5.0,  .disp = synth.decay_s   },
        .{ .label = "sustain", .idx = 18, .bar = synth.sustain,   .bar_max = 1.0,  .disp = synth.sustain   },
        .{ .label = "release", .idx = 19, .bar = synth.release_s, .bar_max = 10.0, .disp = synth.release_s },
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

    // param 20: filter type
    {
        const is_sel = (app.synth_cursor == 20);
        if (is_sel) try w.writeAll(sel);
        try w.writeAll("  type       ");
        const ft_names = [_][]const u8{ "lp", "hp", "bp", "ntch" };
        const ft_idx: usize = switch (synth.filter_type) {
            .lp => 0, .hp => 1, .bp => 2, .notch => 3,
        };
        for (ft_names, 0..) |nm, i| {
            if (i == ft_idx) {
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

    // param 21: cutoff — log-scale bar, kHz display above 1000 Hz
    {
        const is_sel = (app.synth_cursor == 21);
        if (is_sel) try w.writeAll(sel);
        try w.writeAll("  cutoff   ");
        const log_norm = std.math.log2(synth.filter_cutoff / 20.0) /
                         std.math.log2(20_000.0 / 20.0);
        try synthBar(w, log_norm, 1.0);
        if (synth.filter_cutoff >= 1_000.0)
            try w.print("  {d:.2} kHz", .{synth.filter_cutoff / 1_000.0})
        else
            try w.print("  {d:.0} Hz", .{synth.filter_cutoff});
        try endLine(w);
    }

    // param 22: res
    {
        const is_sel = (app.synth_cursor == 22);
        if (is_sel) try w.writeAll(sel);
        try w.writeAll("  res      ");
        try synthBar(w, synth.filter_res, 1.0);
        try w.print("  {d:.3}", .{synth.filter_res});
        try endLine(w);
    }

    // param 23: fenv amount (bipolar)
    {
        const is_sel = (app.synth_cursor == 23);
        if (is_sel) try w.writeAll(sel);
        try w.writeAll("  f.env.amt ");
        try synthBar(w, synth.fenv_amount + 4.0, 8.0);
        const sign: []const u8 = if (synth.fenv_amount >= 0.0) "+" else "";
        try w.print("  {s}{d:.1} oct", .{ sign, synth.fenv_amount });
        try endLine(w);
    }

    // ── FENV ─────────────────────────────────────
    try synthSection(w, "FENV");

    const fenv_rows = [_]struct { label: []const u8, idx: u8, bar: f32, bar_max: f32, disp: f32 }{
        .{ .label = "f.attack",  .idx = 24, .bar = synth.fenv_attack_s,  .bar_max = 5.0,  .disp = synth.fenv_attack_s  },
        .{ .label = "f.decay",   .idx = 25, .bar = synth.fenv_decay_s,   .bar_max = 5.0,  .disp = synth.fenv_decay_s   },
        .{ .label = "f.sustain", .idx = 26, .bar = synth.fenv_sustain,   .bar_max = 1.0,  .disp = synth.fenv_sustain   },
        .{ .label = "f.release", .idx = 27, .bar = synth.fenv_release_s, .bar_max = 10.0, .disp = synth.fenv_release_s },
    };
    for (fenv_rows, 0..) |p, ri| {
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

    // ── LFO ──────────────────────────────────────
    try synthSection(w, "LFO");

    // param 28: lfo_shape
    {
        const is_sel = (app.synth_cursor == 28);
        if (is_sel) try w.writeAll(sel);
        try w.writeAll("  shape      ");
        const lfo_names = [_][]const u8{ "sine", "tri", "saw", "sqr" };
        const lfo_idx: usize = switch (synth.lfo_shape) {
            .sine => 0, .triangle => 1, .saw => 2, .square => 3,
        };
        for (lfo_names, 0..) |nm, i| {
            if (i == lfo_idx) {
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

    // params 29–30: rate, depth
    {
        const lfo_bar_rows = [_]struct { label: []const u8, idx: u8, bar: f32, bar_max: f32, disp: f32, unit: []const u8 }{
            .{ .label = "rate",  .idx = 29, .bar = synth.lfo_rate_hz, .bar_max = 20.0, .disp = synth.lfo_rate_hz, .unit = " Hz" },
            .{ .label = "depth", .idx = 30, .bar = synth.lfo_depth,   .bar_max = 1.0,  .disp = synth.lfo_depth,   .unit = ""    },
        };
        for (lfo_bar_rows) |p| {
            const is_sel = (app.synth_cursor == p.idx);
            if (is_sel) try w.writeAll(sel);
            try w.print("  {s: <9}", .{p.label});
            try synthBar(w, p.bar, p.bar_max);
            try w.print("  {d:.2}{s}", .{ p.disp, p.unit });
            try endLine(w);
        }
    }

    // param 31: lfo_target
    {
        const is_sel = (app.synth_cursor == 31);
        if (is_sel) try w.writeAll(sel);
        try w.writeAll("  target     ");
        const tgt_names = [_][]const u8{ "off", "filt", "pitch", "amp" };
        const tgt_idx: usize = switch (synth.lfo_target) {
            .none => 0, .filter => 1, .pitch => 2, .amp => 3,
        };
        for (tgt_names, 0..) |nm, i| {
            if (i == tgt_idx) {
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

    // ── VOICE ────────────────────────────────────
    try synthSection(w, "VOICE");

    // param 32: voice_mode
    {
        const is_sel = (app.synth_cursor == 32);
        if (is_sel) try w.writeAll(sel);
        try w.writeAll("  mode       ");
        const mode_names = [_][]const u8{ "poly", "mono", "lgto" };
        const mode_idx: usize = switch (synth.voice_mode) {
            .poly => 0, .mono => 1, .legato => 2,
        };
        for (mode_names, 0..) |nm, i| {
            if (i == mode_idx) {
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

    // param 33: glide
    {
        const is_sel = (app.synth_cursor == 33);
        if (is_sel) try w.writeAll(sel);
        try w.writeAll("  glide    ");
        try synthBar(w, synth.glide_s, 10.0);
        if (synth.glide_s == 0.0) {
            try w.writeAll("  off");
        } else {
            try w.print("  {d:.3} s", .{synth.glide_s});
        }
        try endLine(w);
    }

    // ── SUB ──────────────────────────────────────
    try synthSection(w, "SUB");

    // param 34: sub_level
    {
        const is_sel  = (app.synth_cursor == 34);
        const active  = synth.sub_level > 0.0;
        if (is_sel) try w.writeAll(sel);
        if (!is_sel and !active) try w.writeAll(dim);
        try w.writeAll("  level    ");
        try synthBar(w, synth.sub_level, 1.0);
        if (synth.sub_level == 0.0) try w.writeAll("  off")
        else try w.print("  {d:.2}", .{synth.sub_level});
        if (!is_sel and !active) try w.writeAll(rst);
        try endLine(w);
    }

    // param 35: sub_shape
    {
        const is_sel  = (app.synth_cursor == 35);
        const b_active = synth.sub_level > 0.0;
        if (is_sel) try w.writeAll(sel);
        if (!is_sel and !b_active) try w.writeAll(dim);
        try w.writeAll("  shape      ");
        const sh_names = [_][]const u8{ "sine", "sqr" };
        const sh_idx: usize = switch (synth.sub_shape) { .sine => 0, .square => 1 };
        for (sh_names, 0..) |nm, i| {
            if (i == sh_idx) {
                if (!is_sel and b_active) try w.writeAll(acc ++ bold);
                try w.print("[{s: <5}]", .{nm});
                if (!is_sel and b_active) try w.writeAll(rst);
            } else {
                try w.print(" {s: <5} ", .{nm});
            }
        }
        if (!is_sel and !b_active) try w.writeAll(rst);
        try endLine(w);
    }

    // ── NOISE ────────────────────────────────────
    try synthSection(w, "NOISE");

    // param 36: noise_level
    {
        const is_sel = (app.synth_cursor == 36);
        const active = synth.noise_level > 0.0;
        if (is_sel) try w.writeAll(sel);
        if (!is_sel and !active) try w.writeAll(dim);
        try w.writeAll("  level    ");
        try synthBar(w, synth.noise_level, 1.0);
        if (synth.noise_level == 0.0) try w.writeAll("  off")
        else try w.print("  {d:.2}", .{synth.noise_level});
        if (!is_sel and !active) try w.writeAll(rst);
        try endLine(w);
    }

    // param 37: noise_color
    {
        const is_sel = (app.synth_cursor == 37);
        const active = synth.noise_level > 0.0;
        if (is_sel) try w.writeAll(sel);
        if (!is_sel and !active) try w.writeAll(dim);
        try w.writeAll("  color    ");
        try synthBar(w, synth.noise_color, 1.0);
        try w.print("  {d:.2}", .{synth.noise_color});
        const hint: []const u8 = if (synth.noise_color < 0.33) "  dark"
            else if (synth.noise_color > 0.66) "  white"
            else "  warm";
        try w.writeAll(hint);
        if (!is_sel and !active) try w.writeAll(rst);
        try endLine(w);
    }

    // ── OUT ──────────────────────────────────────
    try synthSection(w, "OUT");

    {
        const is_sel = (app.synth_cursor == 38);
        if (is_sel) try w.writeAll(sel);
        try w.writeAll("  gain     ");
        try synthBar(w, synth.gain, 1.0);
        try w.print("  {d:.3}", .{synth.gain});
        try endLine(w);
    }

    // drawSynthEditorFull renders exactly 51 rows; the caller (drawSynthEditor)
    // is responsible for slicing and padding to fit the terminal height.
}

// ---------------------------------------------------------------------------
// Piano roll
// ---------------------------------------------------------------------------

const note_names = [_][]const u8{
    "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
};

fn pitchLabel(pitch: u7, buf: *[5]u8) []const u8 {
    const octave: i32 = @divTrunc(@as(i32, pitch), 12) - 1;
    const name = note_names[pitch % 12];
    var len: usize = 0;
    @memcpy(buf[0..name.len], name);
    len += name.len;
    if (octave < 0) {
        buf[len] = '-';
        len += 1;
        buf[len] = '0' + @as(u8, @intCast(-octave));
        len += 1;
    } else {
        buf[len] = '0' + @as(u8, @intCast(octave));
        len += 1;
    }
    return buf[0..len];
}

fn isBlackKey(pitch: u7) bool {
    return switch (pitch % 12) {
        1, 3, 6, 8, 10 => true,
        else => false,
    };
}

pub fn drawPianoRoll(app: anytype, w: *std.Io.Writer, rows: usize, snap: engine_mod.UiSnapshot) !void {
    if (app.piano_track >= app.racks.items.len) return;
    const rack = app.racks.items[app.piano_track];
    const pp = if (rack.pattern_player != null)
        &app.racks.items[app.piano_track].pattern_player.?
    else return;

    // Playhead step within the loop (maxInt when stopped — never matches a visible step).
    const play_step: u16 = if (snap.playing) blk: {
        const sr: f64 = @floatFromInt(app.project.sample_rate);
        const bpm: f64 = app.project.tempo_bpm;
        const raw_beats: f64 = @as(f64, @floatFromInt(snap.position_frames)) / (sr * 60.0 / bpm);
        break :blk @intFromFloat(@mod(raw_beats, pp.length_beats) * 4.0);
    } else std.math.maxInt(u16);

    const name = if (app.piano_track < app.project.tracks.items.len)
        app.project.tracks.items[app.piano_track].name
    else "?";

    try w.writeAll(bold ++ " PIANO ROLL" ++ rst);
    try w.print(" \"{s}\"", .{name});
    try w.writeAll(dim ++ "  [hjkl:move  n:note  d:del  []:len  +/-:bars  esc:back]");
    try endLine(w);

    const vis_cols: usize = 16;
    // 3 internal header rows (title + col labels + loop marker) + vis_rows note rows
    // + outer header(2) + footer(3) must fit within `rows`, so max note rows = rows - 8.
    const vis_rows: usize = @min(rows -| 8, 24);
    const left: u16 = app.piano_scroll_step;

    // Column header: beat markers (prefix = 5-char label + 1-char │ = 6 visual cols)
    try w.writeAll(dim ++ "      " ++ rst);
    for (0..vis_cols) |col| {
        const step = left + @as(u16, @intCast(col));
        if (step % 4 == 0) {
            try w.writeAll(dim);
            try w.print("{d:<3}", .{step / 4 + 1});
            try w.writeAll(rst);
        } else {
            try w.writeAll(dim ++ "·  " ++ rst);
        }
    }
    try endLine(w);

    // Loop-end / playhead marker row (between header and notes)
    const loop_step: u16 = @intFromFloat(pp.length_beats * 4.0);
    try w.writeAll(dim ++ "      " ++ rst);
    for (0..vis_cols) |col| {
        const step = left + @as(u16, @intCast(col));
        if (step == play_step) {
            try w.writeAll(grn ++ bold ++ "▾  " ++ rst);
        } else if (step == loop_step) {
            try w.writeAll(acc ++ "┤  " ++ rst);
        } else if (step % 4 == 0) {
            try w.writeAll(dim ++ "│  " ++ rst);
        } else {
            try w.writeAll("   ");
        }
    }
    try endLine(w);

    // Note rows (top of view = high pitch)
    const top: u7 = app.piano_scroll_pitch;
    for (0..vis_rows) |row| {
        const pitch_i: i32 = @as(i32, top) - @as(i32, @intCast(row));
        if (pitch_i < 0 or pitch_i > 127) {
            try endLine(w);
            continue;
        }
        const pitch: u7 = @intCast(pitch_i);
        const black = isBlackKey(pitch);
        const is_cur_row = (pitch == app.piano_cursor_pitch);

        var lbuf: [5]u8 = undefined;
        const label = pitchLabel(@intCast(pitch), &lbuf);
        if (black) try w.writeAll(dim);
        try w.print(" {s: <4}", .{label});
        if (black) try w.writeAll(rst);
        try w.writeAll(dim ++ "│" ++ rst);

        for (0..vis_cols) |col| {
            const step = left + @as(u16, @intCast(col));
            const beat_pos = @as(f64, @floatFromInt(step)) * 0.25;
            const is_cur = is_cur_row and (step == app.piano_cursor_step);
            const starts = pp.noteStartsAt(pitch, beat_pos);
            const covers = pp.noteCovers(pitch, beat_pos);

            if (is_cur) {
                try w.writeAll(sel);
                if (starts) try w.writeAll("[  ")
                else if (covers) try w.writeAll("=  ")
                else try w.writeAll("·  ");
                try w.writeAll(rst);
            } else if (starts) {
                try w.writeAll(acc ++ bold ++ "[" ++ rst ++ acc ++ "= " ++ rst);
            } else if (covers) {
                try w.writeAll(acc ++ "=  " ++ rst);
            } else if (step % 4 == 0) {
                try w.writeAll(dim ++ "│  " ++ rst);
            } else {
                if (black) try w.writeAll(dim);
                try w.writeAll("·  ");
                if (black) try w.writeAll(rst);
            }
        }
        try endLine(w);
    }

    // used includes the 2 outer rows (header + hr) so padding aligns with drum-grid convention
    const used = 5 + vis_rows;
    for (used..@max(used, rows -| 3)) |_| try endLine(w);
}

pub fn drawPianoRollStatus(app: anytype, w: *std.Io.Writer) !void {
    if (app.piano_track >= app.racks.items.len) return;
    const rack = app.racks.items[app.piano_track];
    const pp = if (rack.pattern_player != null)
        &app.racks.items[app.piano_track].pattern_player.?
    else return;

    var lbuf: [5]u8 = undefined;
    const label = pitchLabel(@intCast(app.piano_cursor_pitch), &lbuf);
    const beat_pos = @as(f64, @floatFromInt(app.piano_cursor_step)) * 0.25;
    const bar = app.piano_cursor_step / 4 + 1;
    const sub = app.piano_cursor_step % 4 + 1;

    try w.writeAll(acc ++ sel ++ " PIANO " ++ rst);
    try w.writeAll(dim ++ "  " ++ rst);
    try w.print("{s}", .{label});
    try w.writeAll(dim ++ "  bar " ++ rst);
    try w.print("{d}.{d}", .{ bar, sub });
    try w.writeAll(dim ++ "  len " ++ rst);
    try w.print("{d:.2}b", .{app.piano_note_len});
    try w.writeAll(dim ++ "  loop " ++ rst);
    try w.print("{d:.0}b", .{pp.length_beats});
    // Note count at cursor pitch
    var n_here: usize = 0;
    _ = beat_pos;
    for (pp.notes[0..pp.note_count]) |n| {
        if (n.pitch == app.piano_cursor_pitch) n_here += 1;
    }
    try w.writeAll(dim ++ "  notes " ++ rst);
    try w.print("{d}/{d}", .{ n_here, pp.note_count });
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}

pub fn drawSynthStatus(app: anytype, w: *std.Io.Writer) !void {
    if (app.synth_track >= app.racks.items.len) return;
    const rack = app.racks.items[app.synth_track];
    switch (rack.instrument) { .poly_synth => {}, else => return }
    const synth = &rack.instrument.poly_synth;

    const labels = [_][]const u8{
        "waveform", "pls.width", "detune", "unison", "uni.det", "spread",
        "b.on", "b.waveform", "b.pw", "b.semi", "b.detune", "b.level", "b.unison", "b.uni.det",
        "mod.mode", "mod.amount",
        "attack", "decay", "sustain", "release",
        "filt.type", "cutoff", "res", "f.env.amt",
        "f.attack", "f.decay", "f.sustain", "f.release",
        "lfo.shape", "lfo.rate", "lfo.depth", "lfo.target",
        "voice.mode", "glide",
        "sub.level", "sub.shape",
        "noise.level", "noise.color",
        "gain",
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
        1  => try w.print("{d:.2}",       .{synth.pulse_width}),
        2  => try w.print("{d:.0} ct",    .{synth.detune_cents}),
        3  => try w.print("{d}",           .{synth.unison}),
        4  => try w.print("{d:.1} ct",    .{synth.unison_detune}),
        5  => try w.print("{d:.2}",       .{synth.unison_spread}),
        6  => try w.writeAll(if (synth.osc_b_on) "on" else "off"),
        7  => try w.writeAll(switch (synth.osc_b_waveform) {
            .sine => "sine", .saw => "saw", .triangle => "tri", .square => "sqr",
        }),
        8  => try w.print("{d:.2}",       .{synth.osc_b_pulse_width}),
        9  => try w.print("{d:.0} st",    .{synth.osc_b_semi}),
        10 => try w.print("{d:.0} ct",    .{synth.osc_b_detune_cents}),
        11 => try w.print("{d:.2}",       .{synth.osc_b_level}),
        12 => try w.print("{d}",           .{synth.osc_b_unison}),
        13 => try w.print("{d:.1} ct",    .{synth.osc_b_unison_detune}),
        14 => try w.writeAll(switch (synth.mod_mode) {
            .none => "off", .ring => "ring",
            .am_a_to_b => "AM A\u{2192}B", .am_b_to_a => "AM B\u{2192}A",
            .fm_a_to_b => "FM A\u{2192}B", .fm_b_to_a => "FM B\u{2192}A",
        }),
        15 => switch (synth.mod_mode) {
            .fm_a_to_b, .fm_b_to_a => try w.print("\u{03b2}={d:.2}", .{synth.mod_amount}),
            else                    => try w.print("{d:.2}",          .{synth.mod_amount}),
        },
        16 => try w.print("{d:.3} s",     .{synth.attack_s}),
        17 => try w.print("{d:.3} s",     .{synth.decay_s}),
        18 => try w.print("{d:.3}",       .{synth.sustain}),
        19 => try w.print("{d:.3} s",     .{synth.release_s}),
        20 => try w.writeAll(switch (synth.filter_type) {
            .lp => "lp", .hp => "hp", .bp => "bp", .notch => "notch",
        }),
        21 => if (synth.filter_cutoff >= 1_000.0)
            try w.print("{d:.2} kHz", .{synth.filter_cutoff / 1_000.0})
        else
            try w.print("{d:.0} Hz",  .{synth.filter_cutoff}),
        22 => try w.print("{d:.3}",       .{synth.filter_res}),
        23 => {
            const sign: []const u8 = if (synth.fenv_amount >= 0.0) "+" else "";
            try w.print("{s}{d:.1} oct",  .{ sign, synth.fenv_amount });
        },
        24 => try w.print("{d:.3} s",     .{synth.fenv_attack_s}),
        25 => try w.print("{d:.3} s",     .{synth.fenv_decay_s}),
        26 => try w.print("{d:.3}",       .{synth.fenv_sustain}),
        27 => try w.print("{d:.3} s",     .{synth.fenv_release_s}),
        28 => try w.writeAll(switch (synth.lfo_shape) {
            .sine => "sine", .triangle => "tri", .saw => "saw", .square => "sqr",
        }),
        29 => try w.print("{d:.2} Hz",    .{synth.lfo_rate_hz}),
        30 => try w.print("{d:.2}",       .{synth.lfo_depth}),
        31 => try w.writeAll(switch (synth.lfo_target) {
            .none => "off", .filter => "filter", .pitch => "pitch", .amp => "amp",
        }),
        32 => try w.writeAll(switch (synth.voice_mode) {
            .poly => "poly", .mono => "mono", .legato => "legato",
        }),
        33 => if (synth.glide_s == 0.0) try w.writeAll("off")
              else try w.print("{d:.3} s", .{synth.glide_s}),
        34 => if (synth.sub_level == 0.0) try w.writeAll("off")
              else try w.print("{d:.2}",   .{synth.sub_level}),
        35 => try w.writeAll(switch (synth.sub_shape) { .sine => "sine", .square => "sqr" }),
        36 => if (synth.noise_level == 0.0) try w.writeAll("off")
              else try w.print("{d:.2}",   .{synth.noise_level}),
        37 => try w.print("{d:.2}",       .{synth.noise_color}),
        38 => try w.print("{d:.3}",       .{synth.gain}),
        else => {},
    }
    try w.writeAll(rst);
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}

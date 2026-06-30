//! TUI rendering. Every function is pure output — no state mutation.
//!
//! Functions that need App fields take `app: anytype` so this module
//! never imports app.zig, avoiding a circular dependency. The compiler
//! instantiates each function with *App at the call site and type-checks
//! the field accesses there.

const std = @import("std");
const ws = @import("wstudio");
const types = ws.types;
const Project = ws.Project;
const Transport = ws.Transport;
const DrumMachine = ws.dsp.DrumMachine;
const eq_mod = ws.dsp.eq;
const cmd_mod = @import("cmd.zig");
const engine_mod = ws.engine;
const pattern_mod = ws.dsp.pattern;
const midi = ws.midi;

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
const blu  = "\x1b[34m";   // blue   – voice / routing
const mag  = "\x1b[35m";   // magenta – modulation / movement
const bcyn = "\x1b[96m";   // bright cyan – cursor / selected row
const bwht = "\x1b[97m";   // bright white – selected value

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

    for (app.session.project.tracks.items, 0..) |track, i| {
        const inst_tag = std.meta.activeTag(app.session.racks.items[i].instrument);
        const is_empty = inst_tag == .empty;
        const label: []const u8 = if (is_empty) "-- empty --" else app.session.racks.items[i].label;
        const hint: []const u8 = switch (inst_tag) {
            .empty => " [enter:insert]",
            .drum_machine => " [enter:grid]",
            else => " [enter:edit]",
        };
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
        if (!is_empty and i < app.session.racks.items.len) {
            const rfx = app.session.racks.items[i].fx;
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

    const used = 3 + app.session.project.tracks.items.len;
    for (used..@max(used, rows -| 3)) |_| try endLine(w);
}

/// Names + one-line descriptions for the instrument picker. Order must match
/// `app.picker_kinds`.
const picker_menu = [_]struct { name: []const u8, desc: []const u8 }{
    .{ .name = "Synth",        .desc = "subtractive/FM polysynth — piano-roll sequenceable" },
    .{ .name = "Sampler",      .desc = "one clip played chromatically — :load-sample to swap" },
    .{ .name = "Drum Machine", .desc = "8-pad step sequencer with per-pad sampler" },
};

pub fn drawInstrumentPicker(app: anytype, w: *std.Io.Writer, rows: usize) !void {
    const track_name = if (app.cursor < app.session.project.tracks.items.len)
        app.session.project.tracks.items[app.cursor].name
    else
        "?";

    try w.writeAll(bold ++ " INSERT INSTRUMENT" ++ rst);
    try w.writeAll(acc);
    try w.print("  \"{s}\"", .{track_name});
    try w.writeAll(rst);
    try endLine(w);
    try endLine(w);

    for (picker_menu, 0..) |item, i| {
        const is_sel = (i == app.picker_cursor);
        if (is_sel) try w.writeAll(sel);
        try w.writeAll(if (is_sel) "  > " else "    ");
        try w.print("{s: <14}", .{item.name});
        if (!is_sel) try w.writeAll(dim);
        try w.print(" {s}", .{item.desc});
        try w.writeAll(rst);
        try endLine(w);
    }

    const used = 2 + picker_menu.len;
    for (used..@max(used, rows -| 3)) |_| try endLine(w);
}

pub fn drawDrumGrid(app: anytype, w: *std.Io.Writer, rows: usize, snap: engine_mod.UiSnapshot) !void {
    _ = snap;
    const playing_step = app.drumMachine().currentStep();
    const is_playing = app.session.engine.uiSnapshot().playing;
    const cur_pad = app.drum_cursor[0];
    const cur_step = app.drum_cursor[1];

    const dm = app.drumMachine();
    const step_count = dm.step_count;
    const track_name = app.session.project.tracks.items[app.drum_track].name;
    try w.writeAll(bold ++ " DRUMS" ++ rst);
    try w.print(" \"{s}\"", .{track_name});
    try w.writeAll(dim ++ "  [hjkl:move  HL:beat  enter:toggle  p:preview  e:sampler  +-:length  X:clear  F:fill  esc:back]");
    try endLine(w);

    // step header — only the active range (step_count) is shown
    try w.writeAll(dim ++ "      ");
    for (0..step_count) |s| {
        if (s % 4 == 0) try w.writeAll("│");
        try w.print("{d:>2} ", .{s + 1});
    }
    try endLine(w);

    for (0..DrumMachine.max_pads) |p| {
        const name = dm.padName(@intCast(p));
        try w.writeAll(dim);
        try w.print(" {s: <4} ", .{name[0..@min(name.len, 4)]});
        try w.writeAll(rst);
        for (0..step_count) |s| {
            if (s % 4 == 0) {
                try w.writeAll(dim ++ "│" ++ rst);
            }
            const active = dm.stepActive(@intCast(p), @intCast(s));
            const is_cursor = (p == cur_pad and s == cur_step);
            const is_play = is_playing and (s == playing_step);

            if (is_cursor) {
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

/// Collects pre-rendered help lines into a fixed buffer so the view can show
/// an arbitrary scroll window instead of spilling off the bottom of the screen.
const HelpText = struct {
    buf: [16384]u8 = undefined,
    len: usize = 0,
    ends: [512]usize = undefined,
    count: usize = 0,

    fn push(self: *HelpText, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch self.buf[self.len..self.len];
        self.len += s.len;
        if (self.count < self.ends.len) {
            self.ends[self.count] = self.len;
            self.count += 1;
        }
    }

    fn section(self: *HelpText, title: []const u8) void {
        self.push("", .{}); // blank spacer
        self.push(bold ++ "  {s}", .{title});
    }

    fn key(self: *HelpText, keys: []const u8, desc: []const u8) void {
        self.push(acc ++ "  {s: <16}" ++ rst ++ dim ++ "{s}", .{ keys, desc });
    }

    fn line(self: *const HelpText, i: usize) []const u8 {
        const start = if (i == 0) 0 else self.ends[i - 1];
        return self.buf[start..self.ends[i]];
    }
};

fn buildHelp(t: *HelpText, cmds: []const cmd_mod.Def) void {
    t.section("COMMANDS");
    for (cmds) |c| t.push(acc ++ "  :{s: <14}" ++ rst ++ dim ++ "{s}", .{ c.name, c.desc });

    t.section("ALL VIEWS");
    t.key("[ / ]",        "master volume down / up  (except piano roll)");
    t.key("space",        "play / pause");
    t.key("gg",           "rewind to start");
    t.key("i",            "enter INSERT mode (play notes)");
    t.key("esc",          "back / return to NORMAL mode");
    t.key(":",            "open command prompt");
    t.key("ctrl-c",       "quit");

    t.section("TRACKS");
    t.key("j / k",        "move cursor down / up");
    t.key("enter",        "edit track (synth or drum grid)");
    t.key("p",            "piano roll for synth tracks");
    t.key("s",            "spectrum + EQ for selected track");
    t.key("m",            "mute / unmute selected track");
    t.key("M",            "master spectrum");
    t.key("< / >",        "pan left / right  (5% per step)");
    t.key("- / +",        "track gain −1 dB / +1 dB  (= also works)");
    t.key("a",            "add synth track");
    t.key("D",            "delete selected track");
    t.key("? / :help",    "this help");

    t.section("INSERT MODE  (piano keyboard)");
    t.key("a s d f g h j k l ;",  "white keys  C D E F G A B C D E");
    t.key("q w r t y i o p",       "black keys  C# D# F# G# A# C# D# F#");
    t.key("z / x",                 "octave down / up");

    t.section("DRUM GRID");
    t.key("h / l",        "move cursor left / right (one step)");
    t.key("H / L",        "move cursor left / right (one beat, coarse)");
    t.key("j / k",        "move cursor down / up (pad)");
    t.key("enter",        "toggle step on/off");
    t.key("p",            "preview pad sound");
    t.key("e",            "open sampler editor for current pad");
    t.key("s",            "spectrum + EQ for drum track");
    t.key("+ / -",        "lengthen / shorten loop (1–16 steps)");
    t.key("X",            "clear all steps on current pad");
    t.key("F",            "fill all steps on current pad");

    t.section("SAMPLER EDITOR");
    t.key("j / k",        "select parameter");
    t.key("h / l",        "adjust value (fine)");
    t.key("H / L",        "adjust value (coarse ×10)");
    t.key("1–8",          "switch to pad 1–8");
    t.key("p",            "audition current pad");
    t.key(":load-pad",    "<0-7> <file.wav>  load a sample into a pad");

    t.section("SYNTH EDITOR");
    t.key("j / k",        "select parameter");
    t.key("{ / }",        "prev / next section");
    t.key("h / l",        "adjust value (fine)");
    t.key("H / L",        "adjust value (coarse ×10)");
    t.key("p",            "open piano roll for this track");
    t.key("s",            "spectrum + EQ for this track");

    t.section("PIANO ROLL");
    t.key("h / l",        "move cursor left / right (one step)");
    t.key("H / L",        "move cursor left / right (one beat, coarse)");
    t.key("j / k",        "move cursor down / up (pitch)");
    t.key("J / K",        "move cursor down / up (one octave)");
    t.key("g / G",        "jump cursor to loop start / end");
    t.key("enter",        "toggle note at cursor");
    t.key("n / d",        "insert / delete note at cursor (aliases)");
    t.key("p",            "preview note at cursor");
    t.key("< / >",        "decrease / increase velocity of note at cursor");
    t.key("e",            "open synth editor for this track");
    t.key("s",            "spectrum + EQ for this track");
    t.key("[ / ]",        "resize note at cursor (else set default length)");
    t.key("+ / -",        "lengthen / shorten loop (1 bar)");
    t.key(":clear",       "erase all notes in the pattern");

    t.section("SPECTRUM / EQ");
    t.key("h / l",        "select EQ band");
    t.key("j / k",        "decrease / increase band gain (1 dB)");
    t.key("J / K",        "decrease / increase band gain (6 dB)");
    t.key("b",            "bypass EQ toggle");
}

/// Renders a scroll window of the help text. `scroll` is clamped in place so
/// the caller's stored offset can never run past the last screenful.
pub fn drawHelp(w: *std.Io.Writer, rows: usize, cmds: []const cmd_mod.Def, scroll: *usize) !void {
    var t = HelpText{};
    buildHelp(&t, cmds);

    const body = rows -| 3; // lines available between the rules
    const visible = body -| 1; // one row reserved for the sticky title
    const max_scroll = t.count -| visible;
    if (scroll.* > max_scroll) scroll.* = max_scroll;
    const off = scroll.*;
    const end = @min(off + visible, t.count);

    // Sticky title with a position indicator.
    try w.writeAll(bold ++ " HELP" ++ rst);
    try w.writeAll(dim ++ "   esc: close   j/k: scroll");
    if (t.count > visible) {
        try w.print("   {d}–{d}/{d}", .{ off + 1, end, t.count });
        if (off < max_scroll) try w.writeAll("  ↓");
        if (off > 0) try w.writeAll("  ↑");
    }
    try endLine(w);

    var i = off;
    while (i < end) : (i += 1) {
        try w.writeAll(t.line(i));
        try endLine(w);
    }

    // Pad any remaining body rows so short windows don't leave stale content.
    for (1 + (end - off)..body) |_| try endLine(w);
}

pub fn drawSpectrumView(
    app: anytype,
    w: *std.Io.Writer,
    rows: usize,
    cols: usize,
    snap: engine_mod.UiSnapshot,
    is_track: bool,
) !void {
    _ = snap;

    const title: []const u8 = if (is_track) blk: {
        const name = if (app.eq_track < app.session.project.tracks.items.len)
            app.session.project.tracks.items[app.eq_track].name
        else
            "?";
        break :blk name;
    } else "MASTER";

    const spectrum_snap = if (is_track)
        app.session.engine.trackSpectrumSnapshot(app.eq_track)
    else
        app.session.engine.masterSpectrumSnapshot();

    // Pre-check whether the EQ row will be drawn so visual_rows can be sized correctly.
    const has_eq = is_track and
        app.eq_track < app.session.racks.items.len and
        app.session.racks.items[app.eq_track].fx.eq != null;
    const eq_row: usize = if (has_eq) 1 else 0;

    // 1 header + visual_rows spectrum + 1 hz label + eq_row must fit in rows-5.
    const visual_rows = @min(spectrum_rows, rows -| (7 + eq_row));
    // Limit band count to available horizontal space (3-char indent + bands).
    const draw_bands = @min(spectrum_band_count, cols -| 5);

    const db_range: f32 = 70.0;
    const db_offset: f32 = -60.0;

    try w.writeAll(bold ++ " SPECTRUM" ++ rst);
    try w.print(" \"{s}\"", .{title});
    try w.writeAll(dim ++ "  [jk:gain  hl:select  b:bypass  esc:back]");
    try endLine(w);

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
            for (0..draw_bands) |band| {
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
            for (0..draw_bands) |_| {
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
    for (0..draw_bands) |band| {
        if (fi < freq_labels.len and band == freq_labels[fi].idx) {
            const label = freq_labels[fi].label;
            if (band + label.len < draw_bands) {
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

    if (has_eq) {
        const e = &app.session.racks.items[app.eq_track].fx.eq.?;
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

    // Pad to fill the view's row budget (rows-5) so the footer stays pinned.
    // lines written: 1 (header) + visual_rows + 1 (hz label) + eq_row = 2 + visual_rows + eq_row
    const used = 4 + visual_rows + eq_row; // "+2 over lines-written" matches other views
    for (used..@max(used, rows -| 3)) |_| try endLine(w);
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
            try w.print("{d}/{d}", .{ app.cursor + 1, app.session.project.tracks.items.len });
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
    if (is_track and app.eq_track < app.session.racks.items.len) {
        if (app.session.racks.items[app.eq_track].fx.eq) |*e| {
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

/// Smooth horizontal level bar. `color` tints the filled portion; the track is
/// always dim. Fractional fill is rendered with a partial block for the last
/// cell so small changes are visible.
fn synthBar(w: *std.Io.Writer, value: f32, max_val: f32, is_sel: bool, color: []const u8) !void {
    const bar_w: usize = 18;
    const frac = std.math.clamp(value / max_val, 0.0, 1.0) * @as(f32, @floatFromInt(bar_w));
    const full: usize = @intFromFloat(@floor(frac));
    const rem = frac - @floor(frac);
    // U+258F..U+2589 — 1/8 .. 7/8 left blocks.
    const eighths = [_][]const u8{ "", "\u{258F}", "\u{258E}", "\u{258D}", "\u{258C}", "\u{258B}", "\u{258A}", "\u{2589}" };
    const e: usize = @intFromFloat(rem * 8.0);
    const has_part = full < bar_w and e > 0;

    try w.writeAll(dim);
    try w.writeByte('[');
    try w.writeAll(rst);
    // filled cells
    try w.writeAll(color);
    if (is_sel) try w.writeAll(bold);
    for (0..full) |_| try w.writeAll("\u{2588}");
    if (has_part) try w.writeAll(eighths[std.math.clamp(e, 1, 7)]);
    try w.writeAll(rst);
    // empty track
    try w.writeAll(dim);
    const used = full + @as(usize, if (has_part) 1 else 0);
    for (used..bar_w) |_| try w.writeAll("\u{2591}");
    try w.writeByte(']');
    try w.writeAll(rst);
}

/// Colored section divider: `▌ LABEL ─────────` filling to a fixed width.
fn synthSection(w: *std.Io.Writer, label: []const u8, color: []const u8) !void {
    try w.writeAll("  ");
    try w.writeAll(color);
    try w.writeAll(bold);
    try w.writeAll("\u{258C} ");
    try w.writeAll(label);
    try w.writeByte(' ');
    try w.writeAll(rst);
    try w.writeAll(dim);
    const used = 5 + label.len; // "  " + "▌ " + label + " "
    const total = 42;
    if (used < total) for (used..total) |_| try w.writeAll("\u{2500}");
    try endLine(w);
}

/// Left gutter + padded label. Selected rows get a bright `▸` cursor; inactive
/// (dimmed) rows are rendered dim.
fn rowHead(w: *std.Io.Writer, is_sel: bool, dimmed: bool, label: []const u8) !void {
    if (is_sel) {
        try w.writeAll(bcyn);
        try w.writeAll(bold);
        try w.print("\u{25B8} {s: <9}", .{label});
        try w.writeAll(rst);
    } else if (dimmed) {
        try w.writeAll(dim);
        try w.print("  {s: <9}", .{label});
        try w.writeAll(rst);
    } else {
        try w.print("  {s: <9}", .{label});
    }
}

/// Trailing value readout, brightened when selected, dimmed when inactive.
fn rowVal(w: *std.Io.Writer, is_sel: bool, dimmed: bool, s: []const u8) !void {
    try w.writeAll("  ");
    if (is_sel) {
        try w.writeAll(bwht);
        try w.writeAll(bold);
        try w.writeAll(s);
        try w.writeAll(rst);
    } else if (dimmed) {
        try w.writeAll(dim);
        try w.writeAll(s);
        try w.writeAll(rst);
    } else {
        try w.writeAll(s);
    }
}

/// One bar parameter row: `▸ label  [bar]  value`.
fn barRow(
    w: *std.Io.Writer,
    is_sel: bool,
    dimmed: bool,
    color: []const u8,
    label: []const u8,
    value: f32,
    max_val: f32,
    val_str: []const u8,
) !void {
    try rowHead(w, is_sel, dimmed, label);
    try w.writeByte(' ');
    const bc = if (is_sel) bcyn else if (dimmed) dim else color;
    try synthBar(w, value, max_val, is_sel, bc);
    try rowVal(w, is_sel, dimmed, val_str);
    try endLine(w);
}

/// One enum/toggle row: label followed by bracketed options, the active one
/// highlighted in the section color (bright when the row is selected).
fn enumRow(
    w: *std.Io.Writer,
    is_sel: bool,
    dimmed: bool,
    color: []const u8,
    label: []const u8,
    names: []const []const u8,
    idx: usize,
) !void {
    try rowHead(w, is_sel, dimmed, label);
    try w.writeByte(' ');
    for (names, 0..) |nm, i| {
        if (i == idx) {
            try w.writeAll(if (is_sel) bcyn else if (dimmed) dim else color);
            try w.writeAll(bold);
            try w.print("[{s: <5}]", .{nm});
            try w.writeAll(rst);
        } else {
            try w.writeAll(dim);
            try w.print(" {s: <5} ", .{nm});
            try w.writeAll(rst);
        }
    }
    try endLine(w);
}

/// Render the full 51-row synth editor into `w`, applying vertical scroll so
/// it fits within `max_rows`. Always shows the title line, then slices the
/// parameter body to keep the cursor in view.
pub fn drawSynthEditor(app: anytype, w: *std.Io.Writer, rows: usize, snap: engine_mod.UiSnapshot) !void {
    // Available rows for the view body (excludes outer header+hr + transport+hr+status).
    const max_rows = rows -| 5;
    // Clamp scroll so cursor row is visible.
    const cursor_row = @import("app.zig").App.synthParamRow(app.synth_cursor);
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
    if (app.synth_track >= app.session.racks.items.len) return;
    const rack = app.session.racks.items[app.synth_track];
    switch (rack.instrument) { .poly_synth => {}, else => return }
    const synth = &rack.instrument.poly_synth;

    const name = if (app.synth_track < app.session.project.tracks.items.len)
        app.session.project.tracks.items[app.synth_track].name
    else "?";

    // Title.
    try w.writeAll(bcyn ++ bold ++ " \u{2593} SYNTH " ++ rst);
    try w.writeAll(acc);
    try w.print("\"{s}\"", .{name});
    try w.writeAll(rst);
    try w.writeAll(dim ++ "   jk move \u{00B7} hl adjust \u{00B7} HL coarse \u{00B7} {} section \u{00B7} p piano \u{00B7} esc back");
    try endLine(w);

    var buf: [40]u8 = undefined;
    const c = app.synth_cursor;

    // ── OSC A ────────────────────────────────────
    try synthSection(w, "OSC A", acc);

    const wf_names = [_][]const u8{ "sine", "saw", "tri", "sqr" };
    const wf_idx: usize = switch (synth.waveform) {
        .sine => 0, .saw => 1, .triangle => 2, .square => 3,
    };
    try enumRow(w, c == 0, false, acc, "waveform", &wf_names, wf_idx);

    // param 1: pulse width (only meaningful for square)
    try barRow(w, c == 1, synth.waveform != .square, acc, "pls.width", synth.pulse_width, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.pulse_width}));

    // params 2–5: detune, unison, uni.det, spread
    try barRow(w, c == 2, false, acc, "detune", synth.detune_cents + 100.0, 200.0,
        try std.fmt.bufPrint(&buf, "{d:.0} ct", .{synth.detune_cents}));
    try barRow(w, c == 3, false, acc, "unison", @floatFromInt(synth.unison), 16.0,
        try std.fmt.bufPrint(&buf, "{d}", .{synth.unison}));
    try barRow(w, c == 4, false, acc, "uni.det", synth.unison_detune, 100.0,
        try std.fmt.bufPrint(&buf, "{d:.1} ct", .{synth.unison_detune}));
    try barRow(w, c == 5, false, acc, "spread", synth.unison_spread, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.unison_spread}));

    // ── OSC B ────────────────────────────────────
    try synthSection(w, "OSC B", acc);

    const b_on = synth.osc_b_on;
    const on_names = [_][]const u8{ "on", "off" };
    try enumRow(w, c == 6, false, acc, "on/off", &on_names, if (b_on) 0 else 1);

    const wfb_idx: usize = switch (synth.osc_b_waveform) {
        .sine => 0, .saw => 1, .triangle => 2, .square => 3,
    };
    try enumRow(w, c == 7, !b_on, acc, "waveform", &wf_names, wfb_idx);

    try barRow(w, c == 8, !b_on, acc, "pls.width", synth.osc_b_pulse_width, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.osc_b_pulse_width}));
    try barRow(w, c == 9, !b_on, acc, "semi", synth.osc_b_semi + 24.0, 48.0,
        try std.fmt.bufPrint(&buf, "{d:.0}", .{synth.osc_b_semi}));
    try barRow(w, c == 10, !b_on, acc, "detune", synth.osc_b_detune_cents + 100.0, 200.0,
        try std.fmt.bufPrint(&buf, "{d:.0} ct", .{synth.osc_b_detune_cents}));
    try barRow(w, c == 11, !b_on, acc, "level", synth.osc_b_level, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.osc_b_level}));
    try barRow(w, c == 12, !b_on, acc, "unison", @floatFromInt(synth.osc_b_unison), 16.0,
        try std.fmt.bufPrint(&buf, "{d}", .{synth.osc_b_unison}));
    try barRow(w, c == 13, !b_on, acc, "uni.det", synth.osc_b_unison_detune, 100.0,
        try std.fmt.bufPrint(&buf, "{d:.1} ct", .{synth.osc_b_unison_detune}));

    // ── MOD ──────────────────────────────────────
    try synthSection(w, "MOD  (A \u{2194} B)", mag);

    const mod_on = synth.mod_mode != .none;
    const mod_names = [_][]const u8{ "off", "ring", "AM>B", "AM>A", "FM>B", "FM>A" };
    const mod_idx: usize = switch (synth.mod_mode) {
        .none => 0, .ring => 1, .am_a_to_b => 2, .am_b_to_a => 3,
        .fm_a_to_b => 4, .fm_b_to_a => 5,
    };
    try enumRow(w, c == 14, false, mag, "mode", &mod_names, mod_idx);

    {
        const is_fm = switch (synth.mod_mode) { .fm_a_to_b, .fm_b_to_a => true, else => false };
        const vs = if (is_fm)
            try std.fmt.bufPrint(&buf, "\u{03B2}={d:.2}", .{synth.mod_amount})
        else
            try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.mod_amount});
        try barRow(w, c == 15, !mod_on, mag, "amount", synth.mod_amount, 8.0, vs);
    }

    // ── ENV ──────────────────────────────────────
    try synthSection(w, "ENV", grn);

    try barRow(w, c == 16, false, grn, "attack", synth.attack_s, 5.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.attack_s}));
    try barRow(w, c == 17, false, grn, "decay", synth.decay_s, 5.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.decay_s}));
    try barRow(w, c == 18, false, grn, "sustain", synth.sustain, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3}", .{synth.sustain}));
    try barRow(w, c == 19, false, grn, "release", synth.release_s, 10.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.release_s}));

    // ── FILTER ───────────────────────────────────
    try synthSection(w, "FILTER", yel);

    const ft_names = [_][]const u8{ "lp", "hp", "bp", "ntch" };
    const ft_idx: usize = switch (synth.filter_type) {
        .lp => 0, .hp => 1, .bp => 2, .notch => 3,
    };
    try enumRow(w, c == 20, false, yel, "type", &ft_names, ft_idx);

    {
        const log_norm = std.math.log2(synth.filter_cutoff / 20.0) /
            std.math.log2(20_000.0 / 20.0);
        const vs = if (synth.filter_cutoff >= 1_000.0)
            try std.fmt.bufPrint(&buf, "{d:.2} kHz", .{synth.filter_cutoff / 1_000.0})
        else
            try std.fmt.bufPrint(&buf, "{d:.0} Hz", .{synth.filter_cutoff});
        try barRow(w, c == 21, false, yel, "cutoff", log_norm, 1.0, vs);
    }
    try barRow(w, c == 22, false, yel, "res", synth.filter_res, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3}", .{synth.filter_res}));
    {
        const sign: []const u8 = if (synth.fenv_amount >= 0.0) "+" else "";
        try barRow(w, c == 23, false, yel, "f.env.amt", synth.fenv_amount + 4.0, 8.0,
            try std.fmt.bufPrint(&buf, "{s}{d:.1} oct", .{ sign, synth.fenv_amount }));
    }

    // ── FENV ─────────────────────────────────────
    try synthSection(w, "FENV", grn);

    try barRow(w, c == 24, false, grn, "f.attack", synth.fenv_attack_s, 5.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.fenv_attack_s}));
    try barRow(w, c == 25, false, grn, "f.decay", synth.fenv_decay_s, 5.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.fenv_decay_s}));
    try barRow(w, c == 26, false, grn, "f.sustain", synth.fenv_sustain, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3}", .{synth.fenv_sustain}));
    try barRow(w, c == 27, false, grn, "f.release", synth.fenv_release_s, 10.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.fenv_release_s}));

    // ── LFO ──────────────────────────────────────
    try synthSection(w, "LFO", mag);

    const lfo_names = [_][]const u8{ "sine", "tri", "saw", "sqr" };
    const lfo_idx: usize = switch (synth.lfo_shape) {
        .sine => 0, .triangle => 1, .saw => 2, .square => 3,
    };
    try enumRow(w, c == 28, false, mag, "shape", &lfo_names, lfo_idx);

    try barRow(w, c == 29, false, mag, "rate", synth.lfo_rate_hz, 20.0,
        try std.fmt.bufPrint(&buf, "{d:.2} Hz", .{synth.lfo_rate_hz}));
    try barRow(w, c == 30, false, mag, "depth", synth.lfo_depth, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.lfo_depth}));

    const tgt_names = [_][]const u8{ "off", "filt", "pitch", "amp" };
    const tgt_idx: usize = switch (synth.lfo_target) {
        .none => 0, .filter => 1, .pitch => 2, .amp => 3,
    };
    try enumRow(w, c == 31, false, mag, "target", &tgt_names, tgt_idx);

    // ── VOICE ────────────────────────────────────
    try synthSection(w, "VOICE", blu);

    const vm_names = [_][]const u8{ "poly", "mono", "lgto" };
    const vm_idx: usize = switch (synth.voice_mode) {
        .poly => 0, .mono => 1, .legato => 2,
    };
    try enumRow(w, c == 32, false, blu, "mode", &vm_names, vm_idx);

    try barRow(w, c == 33, false, blu, "glide", synth.glide_s, 10.0,
        if (synth.glide_s == 0.0) "off" else try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.glide_s}));

    // ── SUB ──────────────────────────────────────
    try synthSection(w, "SUB", acc);

    try barRow(w, c == 34, false, acc, "level", synth.sub_level, 1.0,
        if (synth.sub_level == 0.0) "off" else try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.sub_level}));
    {
        const sh_names = [_][]const u8{ "sine", "sqr" };
        const sh_idx: usize = switch (synth.sub_shape) { .sine => 0, .square => 1 };
        try enumRow(w, c == 35, synth.sub_level == 0.0, acc, "shape", &sh_names, sh_idx);
    }

    // ── NOISE ────────────────────────────────────
    try synthSection(w, "NOISE", acc);

    try barRow(w, c == 36, false, acc, "level", synth.noise_level, 1.0,
        if (synth.noise_level == 0.0) "off" else try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.noise_level}));
    {
        const hint: []const u8 = if (synth.noise_color < 0.33) "dark"
            else if (synth.noise_color > 0.66) "white" else "warm";
        try barRow(w, c == 37, synth.noise_level == 0.0, acc, "color", synth.noise_color, 1.0,
            try std.fmt.bufPrint(&buf, "{d:.2}  {s}", .{ synth.noise_color, hint }));
    }

    // ── OUT ──────────────────────────────────────
    try synthSection(w, "OUT", bcyn);

    try barRow(w, c == 38, false, bcyn, "gain", synth.gain, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3}", .{synth.gain}));

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

pub fn drawPianoRoll(app: anytype, w: *std.Io.Writer, rows: usize, cols: usize, snap: engine_mod.UiSnapshot) !void {
    if (app.piano_track >= app.session.racks.items.len) return;
    const rack = app.session.racks.items[app.piano_track];
    const pp = if (rack.pattern_player != null)
        &app.session.racks.items[app.piano_track].pattern_player.?
    else return;

    // Playhead step within the loop (maxInt when stopped — never matches a visible step).
    const play_step: u16 = if (snap.playing) blk: {
        const sr: f64 = @floatFromInt(app.session.project.sample_rate);
        const bpm: f64 = app.session.project.tempo_bpm;
        const raw_beats: f64 = @as(f64, @floatFromInt(snap.position_frames)) / (sr * 60.0 / bpm);
        break :blk @intFromFloat(@mod(raw_beats, pp.length_beats) * 4.0);
    } else std.math.maxInt(u16);

    const name = if (app.piano_track < app.session.project.tracks.items.len)
        app.session.project.tracks.items[app.piano_track].name
    else "?";

    try w.writeAll(bold ++ " PIANO ROLL" ++ rst);
    try w.print(" \"{s}\"", .{name});
    try w.writeAll(dim ++ "  [hjkl:move  HL:beat  JK:oct  gG:ends  enter:toggle  <>:vel  []:resize  esc:back]");
    try endLine(w);

    // 3 internal header rows (title + col labels + loop marker) + vis_rows note rows
    // + outer header(2) + footer(3) must fit within `rows`, so max note rows = rows - 8.
    const vis_rows: usize = @min(rows -| 8, 24);
    const left: u16 = app.piano_scroll_step;

    // Show the full loop (+ end-marker column) up to what fits on screen.
    // Prefix = 6 chars (" C4  │"), each step cell = 3 chars.
    const loop_step: u16 = @intFromFloat(pp.length_beats * 4.0);
    const max_step_cols: usize = (cols -| 6) / 3;
    const vis_cols: usize = @min(@as(usize, loop_step) + 1, max_step_cols);

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
                // Shade the note head by velocity: loud = bold, soft = dim.
                const vel = pp.velocityAt(pitch, beat_pos) orelse 0.85;
                const head = if (vel >= 0.8) bold else if (vel < 0.45) dim else "";
                try w.writeAll(acc);
                try w.writeAll(head);
                try w.writeAll("[" ++ rst ++ acc ++ "= " ++ rst);
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
    if (app.piano_track >= app.session.racks.items.len) return;
    const rack = app.session.racks.items[app.piano_track];
    const pp = if (rack.pattern_player != null)
        &app.session.racks.items[app.piano_track].pattern_player.?
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
    if (app.synth_track >= app.session.racks.items.len) return;
    const rack = app.session.racks.items[app.synth_track];
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

// ---------------------------------------------------------------------------
// Sampler editor (per-pad)
// ---------------------------------------------------------------------------

/// Names for the sampler param rows, indexed by `app.sampler_param`. Index 10
/// (root) applies only to the standalone Sampler, not drum pads.
const sampler_param_labels = [_][]const u8{
    "start", "end", "pitch", "attack", "decay", "sustain", "release", "gain", "pan", "reverse", "root",
};

pub fn drawSamplerEditor(
    app: anytype,
    w: *std.Io.Writer,
    rows: usize,
    cols: usize,
    snap: engine_mod.UiSnapshot,
) !void {
    _ = snap;
    const c = app.sampler_param;
    const is_drum = app.sampler_target == .drum;

    // Resolve the pad being edited and the surrounding labels from the target.
    const track_idx = app.sampler_target.track();
    const track_name = if (track_idx < app.session.project.tracks.items.len)
        app.session.project.tracks.items[track_idx].name
    else
        "?";
    const pad_idx = app.drum_cursor[0];
    const pad: *const ws.dsp.Pad = if (is_drum) padOf(app.drumMachine(), pad_idx) else blk: {
        if (app.editingSampler()) |s| break :blk &s.pad;
        break :blk placeholderPad();
    };

    // Body budget: outer header(2) + transport/hr/status(3) = 5 lines reserved.
    const body = rows -| 5;
    var written: usize = 0;

    // ── Title ────────────────────────────────────
    try w.writeAll(bcyn ++ bold ++ " \u{2593} SAMPLER " ++ rst);
    try w.writeAll(acc);
    try w.print("\"{s}\"", .{track_name});
    try w.writeAll(rst ++ dim);
    if (is_drum) {
        try w.print("  pad {d}/{d} ", .{ pad_idx + 1, DrumMachine.max_pads });
        try w.writeAll(rst ++ acc);
        try w.print("\"{s}\"", .{app.drumMachine().padName(pad_idx)});
        try w.writeAll(dim ++ "   jk param \u{00B7} hl adjust \u{00B7} 1-8 pad \u{00B7} p audition \u{00B7} esc back" ++ rst);
    } else {
        try w.writeAll(rst ++ acc);
        try w.print("\"{s}\"", .{if (app.editingSampler()) |s| s.clipName() else "clip"});
        try w.writeAll(dim ++ "   jk param \u{00B7} hl adjust \u{00B7} p audition \u{00B7} :load-sample \u{00B7} esc back" ++ rst);
    }
    try endLine(w);
    written += 1;

    // ── Waveform panel ───────────────────────────
    // The section headers + param rows need ~13 (drum) / ~16 (sampler) lines;
    // give the waveform whatever vertical space remains, capped for readability.
    const param_lines: usize = if (is_drum) 13 else 16;
    const wave_rows: usize = @min(@as(usize, 8), body -| (written + param_lines));
    if (wave_rows >= 2) {
        try drawWaveformPad(w, pad, cols, wave_rows);
        written += wave_rows;
    }

    var buf: [40]u8 = undefined;

    // ── SAMPLE ───────────────────────────────────
    try synthSection(w, "SAMPLE", acc);
    written += 1;
    try barRow(w, c == 0, false, acc, "start", pad.start_norm, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{pad.start_norm}));
    try barRow(w, c == 1, false, acc, "end", pad.end_norm, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{pad.end_norm}));
    {
        const semi = pad.pitch_semitones;
        try barRow(w, c == 2, false, acc, "pitch", semi + 24.0, 48.0,
            try std.fmt.bufPrint(&buf, "{s}{d:.0} st", .{ if (semi >= 0) "+" else "", semi }));
    }
    written += 3;

    // ── AMP ENV ──────────────────────────────────
    try synthSection(w, "AMP ENV", grn);
    written += 1;
    try barRow(w, c == 3, false, grn, "attack", pad.attack_s, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{pad.attack_s}));
    try barRow(w, c == 4, false, grn, "decay", pad.decay_s, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{pad.decay_s}));
    try barRow(w, c == 5, false, grn, "sustain", pad.sustain, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3}", .{pad.sustain}));
    try barRow(w, c == 6, false, grn, "release", pad.release_s, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{pad.release_s}));
    written += 4;

    // ── OUT ──────────────────────────────────────
    try synthSection(w, "OUT", bcyn);
    written += 1;
    try barRow(w, c == 7, false, bcyn, "gain", pad.gain, 2.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{pad.gain}));
    {
        const pan = pad.pan;
        const lab = if (@abs(pan) < 0.005)
            try std.fmt.bufPrint(&buf, "C", .{})
        else if (pan < 0)
            try std.fmt.bufPrint(&buf, "L{d:.0}", .{-pan * 100})
        else
            try std.fmt.bufPrint(&buf, "R{d:.0}", .{pan * 100});
        try barRow(w, c == 8, false, bcyn, "pan", pan + 1.0, 2.0, lab);
    }
    {
        const rev_names = [_][]const u8{ "off", "on" };
        try enumRow(w, c == 9, false, bcyn, "reverse", &rev_names, if (pad.reverse) 1 else 0);
    }
    written += 3;

    // ── KEY (standalone sampler only): the root note ─────────────────────────
    if (!is_drum) {
        try synthSection(w, "KEY", grn);
        written += 1;
        const root: u7 = if (app.editingSampler()) |s| s.root_note else 60;
        var nbuf: [5]u8 = undefined;
        try barRow(w, c == 10, false, grn, "root", @floatFromInt(root), 127.0,
            try std.fmt.bufPrint(&buf, "{s} ({d})", .{ midi.noteName(root, &nbuf), root }));
        written += 1;
    }

    while (written < body) : (written += 1) try endLine(w);
}

/// A shared zero-length pad used when an editor has no real pad to show — keeps
/// drawing renderable without optionals or unreachable branches.
fn placeholderPad() *const ws.dsp.Pad {
    const holder = struct {
        var p: ws.dsp.Pad = .{ .samples = &[_]f32{} };
    };
    return &holder.p;
}

/// Return a const pointer to pad `idx`, or the placeholder when empty.
fn padOf(dm: anytype, idx: u8) *const ws.dsp.Pad {
    if (dm.pads[idx]) |*pad| return pad;
    return placeholderPad();
}

/// Render a centered, filled waveform of `pad` over `wave_rows` rows. Samples
/// inside the play region are drawn in accent; outside is dim. The start/end
/// markers are drawn as bright vertical bars.
fn drawWaveformPad(
    w: *std.Io.Writer,
    pad: *const ws.dsp.Pad,
    cols: usize,
    wave_rows: usize,
) !void {
    const gutter = 2;
    const width = @min(cols -| gutter, @as(usize, 120));
    const len = pad.samples.len;
    if (len == 0) {
        for (0..wave_rows) |_| {
            try w.writeAll(dim ++ "  (no sample)" ++ rst);
            try endLine(w);
        }
        return;
    }

    // Per-column peak amplitude over the column's sample bucket.
    var amp: [120]f32 = undefined;
    var peak: f32 = 1e-6;
    for (0..width) |x| {
        var a: f32 = 0;
        if (len > 0) {
            const lo = x * len / width;
            const hi = @max(lo + 1, (x + 1) * len / width);
            var j = lo;
            while (j < hi and j < len) : (j += 1) a = @max(a, @abs(pad.samples[j]));
        }
        amp[x] = a;
        peak = @max(peak, a);
    }
    // Normalise to the loudest column so quiet samples are still visible.
    const inv_peak = 1.0 / peak;

    const start_col: usize = @intFromFloat(@as(f32, @floatCast(pad.start_norm)) * @as(f32, @floatFromInt(width)));
    const end_col: usize = @intFromFloat(@as(f32, @floatCast(pad.end_norm)) * @as(f32, @floatFromInt(width)));

    const center = @as(f32, @floatFromInt(wave_rows)) / 2.0;
    for (0..wave_rows) |row| {
        try w.writeAll("  ");
        const d_from_center = @abs(@as(f32, @floatFromInt(row)) + 0.5 - center);
        for (0..width) |x| {
            const is_marker = (x == start_col or x == end_col);
            const in_region = x >= start_col and x <= end_col;
            const radius = amp[x] * inv_peak * center;
            const filled = d_from_center <= radius;

            if (is_marker) {
                try w.writeAll(bcyn ++ bold ++ "\u{2503}" ++ rst); // ┃
            } else if (filled) {
                try w.writeAll(if (in_region) acc else dim);
                try w.writeAll("\u{2588}"); // █
                try w.writeAll(rst);
            } else if (row == @as(usize, @intFromFloat(center))) {
                try w.writeAll(dim ++ "\u{2500}" ++ rst); // ─ zero axis
            } else {
                try w.writeByte(' ');
            }
        }
        try endLine(w);
    }
}

pub fn drawSamplerStatus(app: anytype, w: *std.Io.Writer) !void {
    const is_drum = app.sampler_target == .drum;
    const pad_idx = app.drum_cursor[0];
    const pad: *const ws.dsp.Pad = if (is_drum) padOf(app.drumMachine(), pad_idx) else blk: {
        if (app.editingSampler()) |s| break :blk &s.pad;
        break :blk placeholderPad();
    };
    const cur = @min(@as(usize, app.sampler_param), sampler_param_labels.len - 1);

    try w.writeAll(grn ++ sel ++ " SAMPLER " ++ rst);
    if (is_drum) {
        try w.writeAll(dim ++ "  pad " ++ rst);
        try w.print("{d}", .{pad_idx + 1});
    }
    try w.writeAll(dim ++ "  " ++ rst);
    try w.writeAll(sampler_param_labels[cur]);
    try w.writeAll(dim ++ ": " ++ rst);
    try w.writeAll(acc);
    switch (app.sampler_param) {
        0 => try w.print("{d:.2}", .{pad.start_norm}),
        1 => try w.print("{d:.2}", .{pad.end_norm}),
        2 => try w.print("{s}{d:.0} st", .{ if (pad.pitch_semitones >= 0) "+" else "", pad.pitch_semitones }),
        3 => try w.print("{d:.3} s", .{pad.attack_s}),
        4 => try w.print("{d:.3} s", .{pad.decay_s}),
        5 => try w.print("{d:.3}", .{pad.sustain}),
        6 => try w.print("{d:.3} s", .{pad.release_s}),
        7 => try w.print("{d:.2}", .{pad.gain}),
        8 => try w.writeAll(if (@abs(pad.pan) < 0.005) "C" else if (pad.pan < 0) "L" else "R"),
        9 => try w.writeAll(if (pad.reverse) "on" else "off"),
        10 => {
            const root: u7 = if (app.editingSampler()) |s| s.root_note else 60;
            var nbuf: [5]u8 = undefined;
            try w.writeAll(midi.noteName(root, &nbuf));
        },
        else => {},
    }
    try w.writeAll(rst);
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}

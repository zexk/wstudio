//! Help view (scrollable command/keybinding reference).

const std = @import("std");
const ws = @import("wstudio");
const types = ws.types;
const Project = ws.Project;
const Transport = ws.Transport;
const DrumMachine = ws.dsp.DrumMachine;
const eq_mod = ws.dsp.eq;
const cmd_mod = @import("../cmd.zig");
const engine_mod = ws.engine;
const pattern_mod = ws.dsp.pattern;
const midi = ws.midi;
const style = @import("../style.zig");
const icons = @import("../icons.zig");

// Aliases so the moved render bodies reference the shared palette/primitives
// by their original bare names.
const rst = style.rst;
const bold = style.bold;
const dim = style.dim;
const acc = style.acc;
const grn = style.grn;
const yel = style.yel;
const red = style.red;
const sel = style.sel;
const blu = style.blu;
const mag = style.mag;
const bcyn = style.bcyn;
const bwht = style.bwht;
const endLine = style.endLine;
const hr = style.hr;
const meter = style.meter;
const spectrum_rows = style.spectrum_rows;
const spectrum_band_count = style.spectrum_band_count;
const synth_param_count = style.synth_param_count;
const synthBar = style.synthBar;
const synthSection = style.synthSection;
const rowHead = style.rowHead;
const rowVal = style.rowVal;
const barRow = style.barRow;
const enumRow = style.enumRow;

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
    t.key("1–9",          "count prefix repeats a motion (3l, 12h, 2j …)");
    t.key("[ / ]",        "master volume down / up  (except piano roll)");
    t.key("space",        "play / pause");
    t.key("gg",           "rewind to start");
    t.key("i",            "enter INSERT mode (play notes)");
    t.key("esc",          "back / return to NORMAL mode");
    t.key(":",            "open command prompt");
    t.key("(in :) up/down","recall previous / next command");
    t.key("(in :) tab",   "complete the command name");
    t.key("ctrl-c",       "quit");

    t.section("TRACKS");
    t.key("j / k",        "move cursor down / up");
    t.key("enter",        "edit track (synth or drum grid)");
    t.key("p",            "piano roll for synth tracks");
    t.key("s",            "spectrum + EQ for selected track");
    t.key("m",            "mute / unmute selected track");
    t.key("S",            "solo / unsolo selected track");
    t.key("M",            "master spectrum");
    t.key("< / >",        "pan left / right  (5% per step)");
    t.key("- / +",        "track gain −1 dB / +1 dB  (= also works)");
    t.key("a",            "add synth track");
    t.key("D",            "delete selected track");
    t.key("Y",            "duplicate selected track (instrument, FX, clips) at the end");
    t.key("J / K",        "move selected track down / up");
    t.key("R",            "rename selected track (opens :track-rename <n>)");
    t.key("t",            "tap tempo (tap a few times to set bpm)");
    t.key("c",            "toggle the click track (also :metronome [on|off])");
    t.key("u / U",        "undo / redo content edits (notes, drums, clips)");
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
    t.key("c",            "cycle step velocity (100/75/50/25%)");
    t.key("v",            "visual mode: select a step range (all pads) — y/d/P");
    t.key("< / >",        "less / more swing (50–75%)");
    t.key("p",            "preview pad sound");
    t.key("e",            "open sampler editor for current pad");
    t.key("s",            "spectrum + EQ for drum track");
    t.key("+ / -",        "lengthen / shorten loop (1–16 steps)");
    t.key("X",            "clear all steps on current pad");
    t.key("F",            "fill all steps on current pad");
    t.key("[ / ]",        "prev / next pattern variant (A–H)");
    t.key("N",            "new pattern variant (copy of current)");
    t.key("D",            "delete current pattern variant");
    t.key("y / P",        "yank / paste pattern (works across tracks)");
    t.key("(visual) y/d/P", "range yank / clear / paste (v to enter, hjkl to extend)");

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
    t.key("M",            "grab note at cursor — h/l/j/k drag it, esc drops");
    t.key("n / d",        "insert / delete note at cursor (aliases)");
    t.key("p",            "preview note at cursor");
    t.key("< / >",        "decrease / increase velocity of note at cursor");
    t.key("e",            "open synth editor for this track");
    t.key("s",            "spectrum + EQ for this track");
    t.key("[ / ]",        "resize note at cursor (else set default length)");
    t.key("+ / -",        "lengthen / shorten loop (1 bar)");
    t.key("y / P",        "yank / paste pattern (works across tracks)");
    t.key("v",            "visual mode: select a step range (all pitches) — y/d/P");
    t.key(":clear",       "erase all notes in the pattern");

    t.section("ARRANGEMENT");
    t.key("h / l",        "move cursor left / right (one bar)");
    t.key("H / L",        "move cursor left / right (4 bars)");
    t.key("j / k",        "move between track lanes");
    t.key("enter",        "stamp the live pattern as a clip");
    t.key("e",            "edit melodic clip in the piano roll (edits save into the clip)");
    t.key("[ / ]",        "cycle drum pattern variant to stamp");
    t.key("x",            "delete clip at cursor");
    t.key("y / P",        "yank / paste clip (matching track kind)");
    t.key("v",            "visual mode: select a bar range on this lane — y/d/P");
    t.key("< / >",        "move clip left / right by a bar");
    t.key("( / )",        "set loop start / end at cursor bar");
    t.key("b",            "toggle A/B loop on/off");
    t.key("g",            "play from cursor bar");
    t.key("T",            "toggle song / pattern mode");

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
    try w.writeAll(bold ++ " " ++ icons.help ++ " HELP" ++ rst);
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


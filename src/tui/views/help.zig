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

/// A view whose keybindings get their own help section — lets `?` jump
/// straight there instead of always opening on COMMANDS. Views without a
/// dedicated section (instrument picker) fall back to the top.
pub const Section = enum {
    tracks,
    drum_grid,
    sampler_editor,
    synth_editor,
    piano_roll,
    arrangement,
    automation,
    spectrum,
    file_browser,
};

/// Collects pre-rendered help lines into a fixed buffer so the view can show
/// an arbitrary scroll window instead of spilling off the bottom of the screen.
const HelpText = struct {
    buf: [16384]u8 = undefined,
    len: usize = 0,
    ends: [512]usize = undefined,
    count: usize = 0,
    section_start: std.EnumArray(Section, usize) = std.EnumArray(Section, usize).initFill(0),

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

    /// Same as `section`, but remembers the spacer line's index under `tag`
    /// so `scrollForSection` can jump straight to it.
    fn taggedSection(self: *HelpText, tag: Section, title: []const u8) void {
        self.section_start.set(tag, self.count);
        self.section(title);
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
    t.key("gg / home",    "seek playhead to start (gg also moves the cursor in piano roll/drum grid/arrangement)");
    t.key("G / end",      "seek playhead to end of content (G also moves the cursor in piano roll/drum grid)");
    t.key("i",            "enter INSERT mode (play notes)");
    t.key("esc",          "back / return to NORMAL mode");
    t.key(":",            "open command prompt");
    t.key("(in :) up/down","recall previous / next command");
    t.key("(in :) tab",   "complete the command name");
    t.key("/",            "fuzzy-search prompt — tracks (names) and the file browser (filenames) only");
    t.key("n / N",        "repeat last search forward / backward (tracks, file browser)");
    t.key("ctrl-c",       "quit");

    t.section("MOUSE  (additive — every gesture below has a keyboard equivalent)");
    t.key("click",        "select / activate — same as enter (tracks, drum steps, piano notes, list rows)");
    t.key("scroll",       "move the cursor — pitch in the piano roll, value in synth/sampler/FX (ctrl: coarse)");
    t.key("drag",         "paint drum steps, move a piano note or arrangement clip, drag a sampler marker");
    t.key("shift+scroll", "piano roll only: move the step cursor instead of pitch");
    t.key("shift+drag",   "bypass wstudio — your terminal's native text selection (for copy/paste)");

    t.taggedSection(.tracks, "TRACKS");
    t.key("j / k",        "move cursor down / up — one slot past the last track is MASTER");
    t.key("enter",        "edit track (synth or drum grid) — on MASTER: open its FX chain");
    t.key("p",            "piano roll for synth tracks");
    t.key("s",            "FX chain for selected track — on MASTER: same for the bus");
    t.key("m",            "mute / unmute selected track");
    t.key("S",            "solo / unsolo selected track");
    t.key("M",            "jump to the master row and open its FX chain");
    t.key("< / >",        "pan left / right  (5% per step)");
    t.key("- / +",        "track gain −1 dB / +1 dB  (= also works) — on MASTER: master gain");
    t.key("a",            "add synth track");
    t.key("dd",           "delete selected track, no confirm  (n/a on MASTER — it can't be removed)");
    t.key("Y",            "duplicate selected track (instrument, FX, clips) at the end");
    t.key("J / K",        "move selected track down / up");
    t.key("R",            "rename selected track (opens :track-rename <n>)");
    t.key("tab",          "open the arrangement (song timeline) — tab there returns here");
    t.key("t",            "tap tempo (tap a few times to set bpm)");
    t.key("c",            "toggle the click track (also :metronome [on|off])");
    t.key("u / U / ^R",   "undo / redo content edits (notes, drums, clips)");
    t.key("/",            "fuzzy-search track names, n / N repeat forward / backward");
    t.key("? / :help",    "this help");

    t.section("INSERT MODE  (piano keyboard)");
    t.key("a s d f g h j k l ;",  "white keys  C D E F G A B C D E");
    t.key("q w r t y i o p",       "black keys  C# D# F# G# A# C# D# F#");
    t.key("z / x",                 "octave down / up");

    t.taggedSection(.drum_grid, "DRUM GRID");
    t.key("h / l",        "move cursor left / right (one step)");
    t.key("H / L",        "move cursor left / right (one beat, coarse)");
    t.key("j / k",        "move cursor down / up (pad)");
    t.key("g / G",        "jump step cursor to pattern start / end");
    t.key("enter",        "toggle step on/off");
    t.key("c",            "cycle step velocity (100/75/50/25%)");
    t.key("v",            "visual mode: select a step range (all pads) — y/d/P");
    t.key("< / >",        "less / more swing (50–75%)");
    t.key("C",            "cycle current pad's choke group (none/1-4) — same-group pads cut each other off");
    t.key("a",            "preview pad sound");
    t.key("i",            "insert mode: play pads on the qwerty piano (pitch wraps to pad 1-8)");
    t.key("(insert) space","start recording — clicks a one-bar count-in first if stopped");
    t.key("(insert) esc", "back to normal — while playing, hits recorded at the playhead");
    t.key("R",            "rename current pad (opens :pad-rename <n>, 8 chars max)");
    t.key("e",            "open sampler editor for current pad");
    t.key("s",            "FX chain for drum track");
    t.key("+ / -",        "lengthen / shorten loop (1–16 steps)");
    t.key("X",            "clear all steps on current pad");
    t.key("F",            "fill all steps on current pad");
    t.key("[ / ]",        "prev / next pattern variant (A–H)");
    t.key("N",            "new pattern variant (copy of current)");
    t.key("D",            "delete current pattern variant");
    t.key("y / p",        "yank / paste pattern (works across tracks)");
    t.key("(visual) y/d/p", "range yank / clear / paste (v to enter, hjkl to extend)");
    t.key(".",            "repeat last visual-mode range delete/paste at the cursor");

    t.taggedSection(.sampler_editor, "SAMPLER EDITOR");
    t.key("j / k",        "select parameter");
    t.key("g / G",        "jump to first / last parameter");
    t.key("h / l",        "adjust value (fine)");
    t.key("H / L",        "adjust value (coarse ×10)");
    t.key("1–8",          "switch to pad 1–8");
    t.key("a",            "audition current pad");
    t.key(":load-pad",    "<1-8> [file.wav]  load a sample into a pad (omit the file to browse)");

    t.taggedSection(.synth_editor, "SYNTH EDITOR");
    t.key("j / k",        "select parameter");
    t.key("g / G",        "jump to first / last parameter");
    t.key("{ / }",        "prev / next section");
    t.key("h / l",        "adjust value (fine)");
    t.key("H / L",        "adjust value (coarse ×10)");
    t.key("p",            "open piano roll for this track");
    t.key("s",            "FX chain for this track");
    t.key(":synth-preset-save", "<name>  save the current params as a reusable preset");

    t.taggedSection(.piano_roll, "PIANO ROLL");
    t.key("h / l",        "move cursor left / right (one step)");
    t.key("H / L",        "move cursor left / right (one beat, coarse)");
    t.key("j / k",        "move cursor down / up (pitch)");
    t.key("J / K",        "move cursor down / up (one octave)");
    t.key("g / G",        "jump cursor to loop start / end");
    t.key("enter",        "toggle note at cursor");
    t.key("M",            "grab note at cursor — h/l/j/k drag it, esc drops");
    t.key("n / d",        "insert / delete note at cursor (aliases)");
    t.key("a",            "preview note at cursor");
    t.key("i",            "insert mode: play the qwerty piano (a-row/q-row, z/x octave)");
    t.key("(insert) space","start recording — clicks a one-bar count-in first if stopped");
    t.key("(insert) esc", "back to normal — while playing, notes recorded at the playhead");
    t.key("< / >",        "decrease / increase velocity of note at cursor (count-scaled)");
    t.key("e",            "open synth editor for this track");
    t.key("s",            "FX chain for this track");
    t.key("[ / ]",        "resize note at cursor, else set default length (count-scaled)");
    t.key("+ / -",        "lengthen / shorten loop (1 bar)");
    t.key("y / p",        "yank / paste pattern (works across tracks)");
    t.key("v",            "visual mode: select a step range (all pitches) — y/d/p");
    t.key(".",            "repeat the last nudge, drag, or visual range delete/paste");
    t.key("c / C",        "stamp a triad / 7th chord at cursor (:scale-aware)");
    t.key("T",            "toggle grid: straight 1/16 <-> 1/16 triplet");
    t.key("Z",            "toggle zoom: normal <-> compact (see more of a long pattern)");
    t.key(":clear",       "erase all notes in the pattern");
    t.key(":scale",       "[<root> [<type>]|off]  scale highlight + chord-stamp key");

    t.taggedSection(.arrangement, "ARRANGEMENT");
    t.key("h / l",        "move cursor left / right (one bar)");
    t.key("H / L",        "move cursor left / right (4 bars)");
    t.key("j / k",        "move between track lanes");
    t.key("enter",        "stamp the live pattern as a clip");
    t.key("e",            "edit melodic clip in the piano roll (edits save into the clip)");
    t.key(":load-clip",   "[file.wav]  load a WAV onto a sampler track and stamp it whole at the cursor bar");
    t.key("[ / ]",        "cycle drum pattern variant to stamp");
    t.key("x",            "delete clip at cursor");
    t.key("y / p",        "yank / paste clip (matching track kind)");
    t.key("v",            "visual mode: select a bar range on this lane — y/d/p");
    t.key("< / >",        "move clip left / right by a bar");
    t.key(".",            "repeat the last clip move or visual range delete/paste");
    t.key("( / )",        "set loop start / end at cursor bar");
    t.key("b",            "toggle A/B loop on/off");
    t.key("g",            "play from cursor bar");
    t.key("T",            "toggle song / pattern mode");
    t.key("Z",            "toggle zoom: normal <-> compact (see more of a long song)");
    t.key("a",            "open gain/pan automation editor for the clip at cursor");
    t.key("tab",          "back to the tracks view");

    t.taggedSection(.automation, "AUTOMATION  (per-clip gain/pan breakpoints — opened via 'a' in the arrangement)");
    t.key("h / l",        "move cursor along the clip's beat axis");
    t.key("H / L",        "move cursor by a bar");
    t.key("j / k",        "nudge the value at cursor (fine step) — adds a point if none exists");
    t.key("J / K",        "nudge the value at cursor (coarse step)");
    t.key("x",            "delete the point at cursor exactly");
    t.key("g / G",        "jump cursor to clip start / end");
    t.key("v",            "visual mode: select a step range on the current curve — y/d/p");
    t.key(".",            "repeat the last nudge or visual range delete/paste");
    t.key("tab",          "switch between editing the gain curve and the pan curve");
    t.key("u / U / ^R",   "undo / redo (whole-lane, same as the arrangement's)");
    t.key("esc",          "back to the arrangement");

    t.taggedSection(.spectrum, "FX CHAIN  (same chain view for a track or the master bus)");
    t.key("",             "chains start empty; build them unit by unit, in any order, duplicates allowed");
    t.key("a",            "insert an effect after the focused slot (opens the FX picker)");
    t.key("x",            "remove the focused unit");
    t.key("< / >",        "move the focused unit one slot left / right along the chain");
    t.key("b",            "bypass toggle: the unit keeps its settings but the audio skips it");
    t.key("tab / ] / [",  "walk slot focus along the chain (an EQ unit's editor doubles as the spectrum analyzer)");
    t.key("j / k",        "select a param within the focused unit (EQ: its 10 bands)");
    t.key("h / l",        "decrease / increase the selected param (fine step)");
    t.key("H / L",        "decrease / increase the selected param (coarse step)");
    t.key(":eq",          "<track> [<band> <db>]  first EQ in the chain, from the : prompt (inserts one if missing)");
    t.key(":master-eq",   "[<band> <db>]  same, from the : prompt (M opens the live editor)");
    t.key(":master-comp", "on|off|thresh|ratio|attack|release|makeup <value>  first comp in the master chain");

    t.taggedSection(.file_browser, "FILE BROWSER  (netrw-style; opens on :e, :load-sample, :load-pad, :load-clip with no path)");
    t.key("j / k",        "move cursor");
    t.key("enter / l",    "open directory / pick file");
    t.key("h / backspace","up to the parent directory");
    t.key("g / G",        "jump to first / last entry");
    t.key("~",            "jump to $HOME");
    t.key("/",            "fuzzy-search filenames, n / N repeat forward / backward — matches are highlighted");
    t.key("b",            "bookmark / unbookmark the entry under the cursor (session-only)");
    t.key("B",            "open the bookmark list — enter/l jumps, d removes, esc/q back");
    t.key("esc / q",      "cancel back to the previous view");
}

/// Line offset where `section`'s content starts, so opening help from a
/// given view can land on its own keybindings instead of always the top.
/// `null` (views with no dedicated section, e.g. the instrument picker) opens
/// on COMMANDS as before.
pub fn scrollForSection(section: ?Section, cmds: []const cmd_mod.Def) usize {
    var t = HelpText{};
    buildHelp(&t, cmds);
    return if (section) |s| t.section_start.get(s) else 0;
}

/// Renders a scroll window of the help text. `scroll` is clamped in place so
/// the caller's stored offset can never run past the last screenful.
pub fn drawHelp(w: *std.Io.Writer, rows: usize, cmds: []const cmd_mod.Def, scroll: *usize) !void {
    var t = HelpText{};
    buildHelp(&t, cmds);

    const body = rows -| 5; // lines available between the rules
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


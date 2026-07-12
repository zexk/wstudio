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
    slicer_grid,
};

/// Collects pre-rendered help lines into a fixed buffer so the view can show
/// an arbitrary scroll window instead of spilling off the bottom of the screen.
const HelpText = struct {
    buf: [49152]u8 = undefined,
    len: usize = 0,
    ends: [512]usize = undefined,
    count: usize = 0,
    /// Set when a line didn't fit in `buf`/`ends` — from then on lines render
    /// blank, so the build test below asserts this never trips with the real
    /// command table (it did once: 16K silently blanked every section past
    /// ~line 160 while the count kept climbing).
    truncated: bool = false,
    section_start: std.EnumArray(Section, usize) = std.EnumArray(Section, usize).initFill(0),

    fn push(self: *HelpText, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch blk: {
            self.truncated = true;
            break :blk self.buf[self.len..self.len];
        };
        self.len += s.len;
        if (self.count < self.ends.len) {
            self.ends[self.count] = self.len;
            self.count += 1;
        } else {
            self.truncated = true;
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
    t.key("/",            "search prompt — fuzzy over track names / browser filenames, plain-text in this help");
    t.key("n / N",        "repeat last search forward / backward (tracks, file browser, help)");
    t.key("ctrl-c",       "quit");

    t.section("MOUSE  (additive — every gesture below has a keyboard equivalent)");
    t.key("click",        "select / activate — same as enter (tracks, drum steps, piano notes, list rows)");
    t.key("scroll",       "move the cursor — pitch in the piano roll, value in synth/sampler/FX (ctrl: coarse)");
    t.key("drag",         "paint drum steps, move a piano note or arrangement clip, drag a sampler marker");
    t.key("shift+scroll", "piano roll only: move the step cursor instead of pitch");
    t.key("shift+drag",   "bypass wstudio — your terminal's native text selection (for copy/paste)");

    t.taggedSection(.tracks, "TRACKS");
    t.key("j / k",        "move cursor down / up over rows — tracks, group rows, then MASTER last");
    t.key("enter",        "edit track (synth or drum grid) — on a group row / MASTER: open its FX chain");
    t.key("p",            "piano roll for melodic tracks (synth or sampler)");
    t.key("s",            "FX chain for selected track — same on a group row / MASTER");
    t.key("m",            "mute / unmute selected track");
    t.key("S",            "solo / unsolo selected track");
    t.key("M",            "jump to the master row and open its FX chain");
    t.key("< / >",        "pan left / right  (5% per step)");
    t.key("- / +",        "track gain −1 dB / +1 dB  (= also works) — group row: bus fader; MASTER: master gain");
    t.key("a",            "add synth track");
    t.key("dd",           "delete selected track, no confirm — on a group row: delete the group (members ungroup)");
    t.key("Y",            "duplicate selected track (instrument, FX, clips) at the end");
    t.key("J / K",        "move selected track down / up");
    t.key("[ / ]",        "cycle selected track's color (7 colors + none)");
    t.key("R",            "rename selected track (opens :track-rename <n>) — group row: :group-rename <n>");
    t.key("v",            "visual mode: select a row range — g groups it (opens :group-rename)");
    t.key("z",            "fold / unfold the group under the cursor — its member rows hide behind the group's row");
    t.key(":group-fx <n>", "open group n's FX chain — same shared chain view as a track/master");
    t.key(":track-group",  "<track> <group|none>  assign or clear a track's group by number");
    t.key(":group-del <n>", "delete group n — members fall back to the master mix");
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
    t.key("J / K",        "jump a whole bank of 8 pads (64 pads total, paged 8 at a time)");
    t.key("g / G",        "jump step cursor to pattern start / end");
    t.key("w / b",        "jump to the next / previous bar start");
    t.key("enter",        "toggle step on/off");
    t.key("x",            "clear the step at cursor");
    t.key("c",            "cycle step velocity presets (127/95/63/31)");
    t.key("{ / }",        "nudge step velocity down / up by 1 (count-scaled, full 1-127 range)");
    t.key("v",            "visual mode: select a step range (all pads) — y/d/P");
    t.key("< / >",        "less / more swing (50–75%)");
    t.key("C",            "cycle current pad's choke group (none/1-4) — same-group pads cut each other off");
    t.key("a",            "preview pad sound");
    t.key("i",            "insert mode: play pads on the qwerty piano (pitch wraps to pad 1-64)");
    t.key("(insert) space","start recording — clicks a one-bar count-in first if stopped");
    t.key("(insert) esc", "back to normal — while playing, hits recorded at the playhead");
    t.key("f",            "kit picker — factory + saved kits, / filters by name/tag/author, d deletes a save");
    t.key(":drum-kit-save", "<name>  save pads 0-7's tuning (name/gain/pan/pitch/ADSR/choke, no audio) as a reusable kit");
    t.key("R",            "rename current pad (opens :pad-rename <n>, 8 chars max)");
    t.key("e",            "open sampler editor for current pad");
    t.key("s",            "FX chain for drum track");
    t.key("+ / -",        "lengthen / shorten loop (1–64 steps)");
    t.key("X",            "clear all steps on current pad");
    t.key("F",            "fill all steps on current pad");
    t.key("[ / ]",        "prev / next pattern variant (A–H)");
    t.key("N",            "new pattern variant (copy of current)");
    t.key("D",            "delete current pattern variant");
    t.key("d / y",        "operator: add a motion (h/l/H/L/w/b/g/G, counts work: d3l) to clear / yank that range");
    t.key("dd / yy",      "clear the cursor pad's row / yank the whole pattern");
    t.key("p",            "paste the latest yank (whole pattern or range, works across tracks)");
    t.key("(visual) y/d/p", "range yank / clear / paste (v to enter, hjkl to extend)");
    t.key(".",            "repeat last visual-mode range delete/paste at the cursor");

    t.taggedSection(.slicer_grid, "SLICER");
    t.key("",             "chop one loaded sample into slices, step-sequence the chops");
    t.key(":load-slice",  "[file.wav]  load a WAV as the shared clip (opens the file browser with no path)");
    t.key(":slice",       "<n>  equal-divide the loaded clip into n slices (1-64)");
    t.key("h / l",        "move cursor left / right (one step)");
    t.key("H / L",        "move cursor left / right (one beat, coarse)");
    t.key("j / k",        "move cursor down / up (slice)");
    t.key("J / K",        "jump a whole bank of 8 slices");
    t.key("g / G",        "jump step cursor to pattern start / end");
    t.key("x / enter",    "toggle step on/off");
    t.key("a",            "preview current slice");
    t.key("i",            "insert mode: trigger slices on the qwerty piano (pitch wraps to slice count)");
    t.key("+ / -",        "lengthen / shorten loop (1-64 steps)");
    t.key("[ / ]",        "nudge current slice's start earlier / later");
    t.key("{ / }",        "nudge current slice's end earlier / later");
    t.key("_ / =",        "current slice's gain down / up");
    t.key("< / >",        "current slice's pan left / right");
    t.key("r",            "toggle current slice's reverse");

    t.taggedSection(.sampler_editor, "SAMPLER EDITOR");
    t.key("j / k",        "select parameter");
    t.key("g / G",        "jump to first / last parameter");
    t.key("h / l",        "adjust value (fine)");
    t.key("H / L",        "adjust value (coarse ×10)");
    t.key("1–8",          "switch to pad 1–8 within the current bank of 8");
    t.key("J / K",        "jump a whole bank of 8 pads (same slot, next/prev bank)");
    t.key("a",            "audition current pad");
    t.key(":load-sample", "[file.wav]  load a sample into the cursor pad or sampler track (omit the file to browse)");

    t.taggedSection(.synth_editor, "SYNTH EDITOR");
    t.key("j / k",        "select parameter");
    t.key("g / G",        "jump to first / last parameter");
    t.key("{ / }",        "prev / next section");
    t.key("h / l",        "adjust value (fine)");
    t.key("H / L",        "adjust value (coarse ×10)");
    t.key("p",            "open piano roll for this track");
    t.key("s",            "FX chain for this track");
    t.key("f",            "preset picker — factory + saved patches, / filters by name/tag/author, d deletes a save");
    t.key(":synth-preset-save", "<name>  save the current params as a reusable preset");

    t.taggedSection(.piano_roll, "PIANO ROLL");
    t.key("h / l",        "move cursor left / right (one step)");
    t.key("H / L",        "move cursor left / right (one beat, coarse)");
    t.key("j / k",        "move cursor down / up (pitch)");
    t.key("J / K",        "move cursor down / up (one octave)");
    t.key("g / G",        "jump cursor to loop start / end");
    t.key("w / b",        "jump to the next / previous bar start");
    t.key("enter / n",    "toggle / insert note at cursor");
    t.key("x",            "delete note at cursor");
    t.key("M",            "grab note at cursor — h/l/j/k drag it, esc drops");
    t.key("a",            "preview note at cursor");
    t.key("i",            "insert mode: play the qwerty piano (a-row/q-row, z/x octave)");
    t.key("(insert) space","start recording — clicks a one-bar count-in first if stopped");
    t.key("(insert) esc", "back to normal — while playing, notes recorded at the playhead");
    t.key("< / >",        "decrease / increase velocity of note at cursor (count-scaled)");
    t.key("e",            "open synth editor for this track");
    t.key("s",            "FX chain for this track");
    t.key("[ / ]",        "resize note at cursor, else set default length (count-scaled)");
    t.key("+ / -",        "lengthen / shorten loop (1 bar)");
    t.key("d / y",        "operator: add a motion (h/l/H/L/w/b/g/G, counts work: d3l, y2w) to clear / yank that range");
    t.key("dd / yy",      "clear the cursor pitch's row / yank the whole pattern");
    t.key("p",            "paste the latest yank (whole pattern or range, works across tracks)");
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
    t.key("- / +",        "edge-resize clip length by a bar (content loops to fill it)");
    t.key(".",            "repeat the last clip move / resize or visual range delete/paste");
    t.key("( / )",        "set loop start / end at cursor bar");
    t.key("b",            "toggle A/B loop on/off");
    t.key("g",            "play from cursor bar");
    t.key("T",            "toggle song / pattern mode");
    t.key("Z",            "toggle zoom: normal <-> compact (see more of a long song)");
    t.key("a",            "open gain/pan automation editor for the clip at cursor");
    t.key("/",            "fuzzy-search lane (track) names, n / N repeat forward / backward");
    t.key("tab",          "back to the tracks view");

    t.taggedSection(.automation, "AUTOMATION  (per-clip breakpoints — opened via 'a' in the arrangement)");
    t.key("h / l",        "move cursor along the clip's beat axis");
    t.key("H / L",        "move cursor by a bar");
    t.key("j / k",        "nudge the value at cursor (fine step) — adds a point if none exists");
    t.key("J / K",        "nudge the value at cursor (coarse step)");
    t.key("x",            "delete the point at cursor exactly");
    t.key("g / G",        "jump cursor to clip start / end");
    t.key("v",            "visual mode: select a step range on the current curve — y/d/p");
    t.key(".",            "repeat the last nudge or visual range delete/paste");
    t.key("tab",          "cycle gain -> pan -> instrument params already on this clip -> gain");
    t.key("p",            "pick an instrument param to automate (synth ~30, sampler 9 continuous params)");
    t.key("u / U / ^R",   "undo / redo (whole-lane, same as the arrangement's)");
    t.key("esc",          "back to the arrangement");

    t.taggedSection(.spectrum, "FX CHAIN  (same chain view for a track, the master bus, or a group)");
    t.key("",             "chains start empty; build them unit by unit, in any order, duplicates allowed");
    t.key("a",            "insert an effect after the focused slot (opens the FX picker)");
    t.key("x",            "remove the focused unit");
    t.key("< / >",        "move the focused unit one slot left / right along the chain");
    t.key("b",            "bypass toggle: the unit keeps its settings but the audio skips it");
    t.key("tab / ] / [",  "walk slot focus along the chain (an EQ unit's editor doubles as the spectrum analyzer)");
    t.key("j / k",        "select a param within the focused unit");
    t.key("h / l",        "decrease / increase the selected param (fine step)");
    t.key("H / L",        "decrease / increase the selected param (coarse step)");
    t.key("",             "EQ gets its own scheme instead: h/l picks which of its 8 bands is in view (H/L");
    t.key("",             "  jump 4 at a time), enter opens that band's kind/freq/q/gain-or-slope submenu");
    t.key("",             "  (j/k picks the field there, h/l nudges it, esc backs out to band-select first)");
    t.key("",             "  a band's 'kind' row: h/l cycles peak <-> lowpass <-> highpass; once it's a");
    t.key("",             "  filter the last row becomes 'slope' (12/24/36/48dB/oct) instead of 'gain'");
    t.key("",             "a compressor's 'sidechain' param: h/l cycles none/track N — its envelope then");
    t.key("",             "  detects from track N's signal instead of its own input (duck a bass off a kick)");
    t.key("",             "  'scpad' (next param): h/l cycles none/pad N — narrows detection to one drum pad");
    t.key("",             "  in that track (e.g. just the kick, not the whole kit) instead of its whole mix");
    t.key("",             "Multiband: 2 crossover splits (low/mid/high), each band its own thresh/ratio/");
    t.key("",             "  makeup; 'style' h/l toggles classic (downward only) <-> OTT (also squashes");
    t.key("",             "  quiet signal UP toward the threshold); 'mix' blends dry <-> fully processed");
    t.key("- / +",        "group chain only: bus fader for the whole submix, post-FX (also :group-gain)");

    t.taggedSection(.file_browser, "FILE BROWSER  (netrw-style; opens on :e, :load-sample, :load-clip with no path)");
    t.key("j / k",        "move cursor");
    t.key("enter / l",    "open directory / pick file");
    t.key("h / backspace","up to the parent directory");
    t.key("g / G",        "jump to first / last entry");
    t.key("~",            "jump to $HOME");
    t.key("/",            "fuzzy-search filenames, n / N repeat forward / backward — matches are highlighted");
    t.key("b",            "bookmark / unbookmark the entry under the cursor (persists across sessions)");
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

/// Copy `raw`'s visible bytes (ANSI SGR sequences dropped) into `buf`,
/// truncating if it wouldn't fit. Search matches against this, never the
/// raw line — otherwise a pattern could "match" color-code bytes the user
/// can't see.
fn stripAnsi(raw: []const u8, buf: []u8) []const u8 {
    var i: usize = 0;
    var len: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == 0x1b and i + 1 < raw.len and raw[i + 1] == '[') {
            i += 2;
            while (i < raw.len and !((raw[i] >= 'A' and raw[i] <= 'Z') or (raw[i] >= 'a' and raw[i] <= 'z'))) : (i += 1) {}
            continue; // the loop's own i += 1 consumes the terminator letter
        }
        if (len >= buf.len) break;
        buf[len] = raw[i];
        len += 1;
    }
    return buf[0..len];
}

/// Match `pattern` against the help's rendered lines, starting one line
/// past `start` in `dir` (+1 forward, -1 backward) and wrapping around the
/// whole text — the same walk App.searchTracks/searchBrowser do over their
/// lists. Case-insensitive SUBSTRING match, not the fuzzy subsequence the
/// other searches use: against 70-char prose lines a subsequence is so
/// loose that "sidechain" matches "edit track (synth or drum grid)…" long
/// before the actual sidechain line. Fuzzy earns its keep on short names;
/// prose needs the stricter rule.
pub fn search(cmds: []const cmd_mod.Def, pattern: []const u8, start: usize, dir: i64) ?usize {
    var t = HelpText{};
    buildHelp(&t, cmds);
    if (t.count == 0) return null;
    const n: i64 = @intCast(t.count);
    const anchor: i64 = @intCast(@min(start, t.count - 1));
    var step: i64 = 1;
    while (step <= n) : (step += 1) {
        const idx: usize = @intCast(@mod(anchor + dir * step, n));
        var plain_buf: [512]u8 = undefined;
        if (std.ascii.indexOfIgnoreCase(stripAnsi(t.line(idx), &plain_buf), pattern) != null) return idx;
    }
    return null;
}

/// Write `line` in full-line reverse video: `sel` up front, re-asserted
/// after every embedded reset so the line's interior styling can't switch
/// the highlight back off partway through. endLine's trailing `rst` closes it.
fn writeHighlighted(w: *std.Io.Writer, line: []const u8) !void {
    try w.writeAll(sel);
    var rest = line;
    while (std.mem.indexOf(u8, rest, rst)) |p| {
        try w.writeAll(rest[0 .. p + rst.len]);
        try w.writeAll(sel);
        rest = rest[p + rst.len ..];
    }
    try w.writeAll(rest);
}

/// Renders a scroll window of the help text. `scroll` is clamped in place so
/// the caller's stored offset can never run past the last screenful. `hit`
/// (the last `/` search match, if any) renders reverse-video when in view.
pub fn drawHelp(w: *std.Io.Writer, rows: usize, cmds: []const cmd_mod.Def, scroll: *usize, hit: ?usize) !void {
    var t = HelpText{};
    buildHelp(&t, cmds);

    const body = rows -| 4; // lines available below the caller's header, above transport/status
    const visible = body -| 1; // one row reserved for the sticky title
    const max_scroll = t.count -| visible;
    if (scroll.* > max_scroll) scroll.* = max_scroll;
    const off = scroll.*;
    const end = @min(off + visible, t.count);

    // Sticky title with a position indicator.
    try w.writeAll(bold ++ " " ++ icons.help ++ " HELP" ++ rst);
    try w.writeAll(dim ++ "   esc: close   j/k: scroll   /: search");
    if (t.count > visible) {
        try w.print("   {d}–{d}/{d}", .{ off + 1, end, t.count });
        if (off < max_scroll) try w.writeAll("  ↓");
        if (off > 0) try w.writeAll("  ↑");
    }
    try endLine(w);

    var i = off;
    while (i < end) : (i += 1) {
        if (hit == i) try writeHighlighted(w, t.line(i)) else try w.writeAll(t.line(i));
        try endLine(w);
    }

    // Pad any remaining body rows so short windows don't leave stale content.
    for (1 + (end - off)..body) |_| try endLine(w);
}

/// Help's footer status row: the live `/` prompt while typing, otherwise
/// mode badge + any pending status message + the key hints — same
/// message-before-hints clamp ordering views/browser.zig documents.
pub fn drawHelpStatus(app: anytype, w: *std.Io.Writer, right: *std.Io.Writer) !void {
    try style.writeModeBadge(w, app.modal.mode);
    try style.writeViewBadge(right, "HELP", app.modal.mode);
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
    try w.writeAll(dim ++ "  " ++ rst ++ "j/k: scroll  d/u: page  g/G: top/bottom  /: search  n/N: next/prev  ?/esc: close");
}


test "stripAnsi drops SGR sequences, keeps visible bytes" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("  hi there", stripAnsi("\x1b[36m  hi \x1b[0m\x1b[2mthere", &buf));
    try std.testing.expectEqualStrings("plain", stripAnsi("plain", &buf));
}

test "help search wraps forward from the end; no match is null" {
    const commands = @import("../commands.zig");
    // "master volume" lives in the ALL VIEWS section near the top, so an
    // anchor past the last line (clamped there) only finds it by wrapping.
    try std.testing.expect(search(commands.cmds, "master volume", 100000, 1) != null);
    try std.testing.expectEqual(@as(?usize, null), search(commands.cmds, "zzqqxxjj", 0, 1));
}

test "help text fits its buffers — nothing silently truncated" {
    const commands = @import("../commands.zig");
    var t = HelpText{};
    buildHelp(&t, commands.cmds);
    try std.testing.expect(!t.truncated);
    // Early warning well before the hard cap: growing content should bump
    // the buffer deliberately, not creep up on the blank-lines cliff again.
    try std.testing.expect(t.len + 8192 <= t.buf.len);
    try std.testing.expect(t.count + 64 <= t.ends.len);
}

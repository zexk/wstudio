//! Help content model, shared by both frontends: section tags, the
//! pre-rendered help text (built from the live command table + user
//! keymaps), per-view scroll targets, and plain-text search. Rendering
//! stays with each frontend (tui/views/help.zig, gui/views/help.zig).

const std = @import("std");
const ws = @import("wstudio");
const cmd_mod = @import("cmd.zig");
const config_mod = @import("../config.zig");
const ansi = @import("ansi.zig");

const rst = ansi.rst;
const bold = ansi.bold;
const dim = ansi.dim;
const acc = ansi.acc;

/// A view whose keybindings get their own help section - lets `?` jump
/// straight there instead of always opening on COMMANDS. Views without a
/// dedicated section (instrument picker) fall back to the top.
pub const Section = enum {
    tracks,
    drum_grid,
    sampler_editor,
    soundfont_editor,
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
pub const HelpText = struct {
    buf: [53248]u8 = undefined,
    len: usize = 0,
    ends: [640]usize = undefined,
    count: usize = 0,
    /// Set when a line didn't fit in `buf`/`ends` - from then on lines render
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

    fn group(self: *HelpText, title: []const u8) void {
        self.push(dim ++ "  {s}" ++ rst, .{title});
    }

    fn key(self: *HelpText, keys: []const u8, desc: []const u8) void {
        self.push(acc ++ "  {s: <16}" ++ rst ++ dim ++ "{s}", .{ keys, desc });
    }

    pub fn line(self: *const HelpText, i: usize) []const u8 {
        const start = if (i == 0) 0 else self.ends[i - 1];
        return self.buf[start..self.ends[i]];
    }

    /// Index of the section-title line that governs line `i`, walking back
    /// from it. Both frontends need it: the TUI prints the title in its
    /// sticky header, the GUI also highlights that section in its nav
    /// column, and `{`/`}` jumps step between the hits.
    pub fn sectionLineAt(self: *const HelpText, i: usize) ?usize {
        if (self.count == 0) return null;
        var j = @min(i, self.count - 1) +| 1;
        while (j > 0) {
            j -= 1;
            if (isSectionLine(self.line(j))) return j;
        }
        // Line 0 is always `section`'s blank spacer, so a query that lands
        // on it has nothing behind it - report the section it introduces
        // rather than "none", which every caller would have to special-case.
        return self.nextSectionLine(i);
    }

    /// First section-title line strictly after `from`, or null past the last.
    pub fn nextSectionLine(self: *const HelpText, from: usize) ?usize {
        var j = from +| 1;
        while (j < self.count) : (j += 1) {
            if (isSectionLine(self.line(j))) return j;
        }
        return null;
    }
};

/// A section title is the only row `section` renders bold; `group` uses
/// `dim` and `key` uses `acc`, so the prefix classifies a line without the
/// builders having to carry a parallel tag array.
pub fn isSectionLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, bold);
}

/// `line` (a section row) without its style prefix and two-space indent.
pub fn sectionTitle(line: []const u8) []const u8 {
    return if (isSectionLine(line)) line[bold.len + 2 ..] else line;
}

pub fn buildHelp(t: *HelpText, cmds: []const cmd_mod.Def, keymaps: []const config_mod.Keymap) void {
    // The user-keymap section renders LAST (see end of this function) so
    // registering maps never shifts the tagged sections' scroll offsets.
    t.section("COMMANDS");
    for (cmds) |c| {
        if (cmd_mod.hiddenFromCompletion(c)) continue;
        t.push(acc ++ "  :{s: <14}" ++ rst ++ dim ++ "{s}", .{ c.name, c.desc });
    }

    t.section("WORKSPACE BASICS");
    // zig fmt: off
    t.key("1–9",          "count prefix repeats motions in grid and parameter editors (3l, 12h, 2j …)");
    t.key("[ / ]",        "master volume down / up where the active view does not claim this pair");
    t.key("space",        "play / pause");
    t.key("home",         "seek playhead to start (grid and parameter editors use gg for cursor start)");
    t.key("G / end",      "seek playhead to end of content (visual G and gG move the active view's cursor)");
    t.key("i",            "enter INSERT mode in tracks and pattern editors (play notes)");
    t.key("esc",          "back / return to NORMAL mode");
    t.key(":",            "open command prompt");
    t.key("(in :) up/down","recall previous / next command");
    t.key("(in :) ^P/^N", "recall previous / next command (readline style)");
    t.key("(in :) tab",   "complete the command name");
    t.key("(in :/) ←/→",  "move cursor; home/end or ^A/^E jumps to start/end");
    t.key("(in :/) bs/^W", "delete previous character / word; ^U/^K deletes before / after cursor");
    t.key(":recent",      "open one of the 10 most recently loaded or saved projects");
    t.key("/",            "search prompt - fuzzy over track names / arrangement lanes / browser filenames / synth params, plain-text in this help");
    t.key("n / N",        "repeat last search forward / backward (tracks, arrangement, file browser, synth editor, help)");
    t.key("`",            "jump to the alternate view - the last place you edited (press again to bounce back)");
    t.key("q{a-z} .. q",  "record a macro into register a-z; q (normal mode) stops it");
    t.key("[count]@{a-z}","replay a macro count times; @@ repeats the last replay");
    t.key("",             "  macros capture everything - motions, edits, : commands, insert-mode notes");
    t.key("u / U / ^R",   "undo / redo content edits in every workspace editor");
    t.key("? / :help",    "open this context-sensitive reference");
    t.key("ctrl-c",       "quit");

    t.section("PICKERS  (instrument, effect, automation parameter, preset)");
    t.key("j / k",        "move highlight; g / G jumps to first / last item");
    t.key("enter / space", "apply highlighted item; esc / q cancels");
    t.key("/",            "filter items by name");
    t.key("J / K",        "preset picker only: move 10 items; [ / ] jumps between sections");

    t.section("MOUSE  (additive - every gesture below has a keyboard equivalent)");
    t.key("click",        "select / activate - same as enter (tracks, drum steps, piano notes, list rows)");
    t.key("scroll",       "move the cursor - pitch in piano roll, value in synth/sampler/FX (ctrl: curve on ENV/fade params, coarse elsewhere)");
    t.key("drag",         "paint drum steps, move a piano note or arrangement clip, drag a sampler marker");
    t.key("drag (GUI)",   "piano note edges resize it - right edge sets the length, left edge moves the start");
    t.key("shift+scroll", "piano roll only: move the step cursor instead of pitch");
    t.key("alt+scroll",   "micro-nudge piano or step-grid note under pointer earlier / later");
    t.key("ctrl+drag",    "arrangement only: resize the clip's right edge instead of moving it");
    t.key("shift+drag",   "arrangement only: leave a clone behind - lay one clip down, then strew copies");
    t.key("",             "  across the bar. Most terminals keep shift+drag for their own text selection,");
    t.key("",             "  so the TUI may never see it (y then p instead); the GUI always gets it)");

    t.taggedSection(.tracks, "TRACKS");
    t.group("BASICS");
    t.key("j / k",        "move cursor down / up over rows - tracks, group rows, then MASTER last");
    t.key("enter",        "open the selected instrument editor (a drum machine / slicer opens its pad / slice panel) - on a group row / MASTER: open its FX chain");
    t.key("p",            "note editor - piano roll on a melodic track, step grid on a drum machine / slicer");
    t.key("s",            "FX chain for selected track - same on a group row / MASTER");
    t.key("m",            "mute / unmute selected track - on a group row: the bus's own mute flag");
    t.key("S",            "solo / unsolo selected track - on a group row: the bus's own solo flag");
    t.key("r",            "arm / disarm track for recording - space records live audio input on an armed Audio track");
    t.key("M",            "jump to the master row and open its FX chain");
    t.key("< / >",        "pan left / right  (5% per step)");
    t.key("- / +",        "track gain −1 dB / +1 dB  (= also works) - group row: bus fader; MASTER: master gain");
    t.key("a",            "add synth track - joins the group under the cursor (or the cursor track's own group)");
    t.key("I",            "change selected track's instrument - opens the picker, keeps notes when the old/new kinds are compatible");
    t.key("f",            "preset picker for the selected track - synth patch + its FX chain, drum kit, or SoundFont preset");
    t.key("dd",           "delete selected track, no confirm - on a group row: delete the group (members ungroup)");
    t.key("Y",            "duplicate selected track (instrument, FX, clips) at the end");
    t.key("J / K",        "move selected track down / up");
    t.group("ORGANIZE AND MIX");
    t.key("[ / ]",        "cycle selected track's color (16 colors + none)");
    t.key("R",            "rename selected track (opens :rename <n>) - group row: renames the group instead");
    t.key("v / V",        "visual row range: counts, 0/G endpoints, o swaps ends; g groups, m/S/Y/dd/-+/<>/[] bulk-edit");
    t.key("z",            "fold / unfold the group under the cursor - its member rows hide behind the group's row");
    t.key(":group-fx <n>", "open group n's FX chain - same shared chain view as a track/master");
    t.key(":track-group",  "<track> <group|none>  assign or clear a track's group by number");
    t.key(":group-del <n>", "delete group n - members fall back to the master mix");
    t.key(":ctrl",         "[<n> [shape] [beats] [depth] [phase]]  list, create or retune a modulation controller");
    t.key(":ctrl-bind <n>", "wire controller n to the param under the open synth/sampler/FX editor's cursor");
    t.key(":ctrl-clear <n>", "free controller n and every knob it drives");
    t.key(":cc-learn",     "arm MIDI learn on the param under the cursor - the next knob you move binds to it");
    t.key(":cc",           "[<number>]  list learned MIDI bindings, or bind one by number");
    t.key(":cc-clear",     "[<number>]  drop one MIDI binding, or all of them");
    t.key("tab",          "open the arrangement (song timeline) - tab there returns here; while");
    t.key("",             "  stopped this enables song mode, tabbing back (or opening a pattern");
    t.key("",             "  editor from here) reverts to pattern mode; nothing changes while playing");
    t.key("T",            "toggle song / pattern mode (manual override, same as the arrangement's T)");
    t.key("t",            "tap tempo (tap a few times to set bpm)");
    t.key("c",            "toggle the click track (also :metronome [on|off])");
    t.key("l",            "MASTER row only: reset the integrated LUFS measurement");
    t.key("/",            "fuzzy-search track names, n / N repeat forward / backward");
    t.key("? / :help",    "this help");

    t.section("INSERT MODE  (piano keyboard)");
    t.key("a s d f g h j k l ;",  "white keys  C D E F G A B C D E");
    t.key("q w r t y i o p",       "black keys  C# D# F# G# A# C# D# F#");
    t.key("z / x",                 "octave down / up");

    t.taggedSection(.drum_grid, "DRUM GRID");
    t.group("BASICS");
    t.key("h / l",        "move cursor left / right (one step)");
    t.key("H / L",        "move cursor left / right (one beat, coarse)");
    t.key("j / k",        "move cursor down / up (pad)");
    t.key("J / K",        "jump a whole bank of 8 pads (64 pads total, paged 8 at a time)");
    t.key("0 / gg / gG",   "jump step cursor to start (0 or gg) / end (gG); counted 0 stays a digit");
    t.key("w / b",        "jump to the next / previous beat boundary");
    t.key("zg / zG",       "finer / coarser timing grid (1/4 through 1/128)");
    t.key("enter / n",    "toggle in place / place a hit and advance (count sets spacing)");
    t.key("",             "  hold enter to shape the fresh hit (j/k velocity) until released");
    t.key("x",            "clear the step at cursor");
    t.key("c",            "cycle step velocity presets (127/95/63/31)");
    t.key("{ / }",        "nudge step velocity down / up by 1 (count-scaled, full 1-127 range)");
    t.key("( / )",        "tune the step under the cursor down / up a semitone (±24, count-scaled)");
    t.key("r",            "cycle the step into a roll (off/2/3/4/6/8 hits packed into the step)");
    t.key("%",            "cycle the step's fire chance (100/75/50/25/10%)");
    t.key("T",            "cycle the step's trig condition (1ST, FILL, 1:2, 2:4 … - ANDed with the chance)");
    t.key("!",            "flip the FILL switch every FILL/!FILL step reads - instant variation, no editing");
    t.key("; / '",        "drag the step early / late (±50% of a step) - per-hit feel, where < > swings every off-beat");
    t.key("",             "  cells: [x] plain, (x) tuned, <x> chance/condition/roll, {x} both");
    t.key("v / V",        "visual: a (pad, step) block, j/k grow it / visual line: every pad - y/d/p");
    t.key("< / >",        "less / more swing (50–75%)");
    t.key("C",            "cycle current pad's choke group (none/1-4) - same-group pads cut each other off");
    t.key("a",            "preview pad sound");
    t.key("i",            "insert mode: play pads on the qwerty piano (pitch wraps to pad 1-64)");
    t.key("(insert) space","start recording - clicks a one-bar count-in first if stopped");
    t.key("(insert) esc", "back to normal - while playing, hits recorded at the playhead");
    t.group("SOUND AND PATTERNS");
    t.key("f",            "kit picker - factory + saved kits, / filters by name/tag/author, d deletes a save");
    t.key(":drum-kit-save", "<name>  save pads 0-7's tuning (name/gain/pan/pitch/ADSR/choke, no audio) as a reusable kit");
    t.key(":spread",      "[semitones]  ramp pitch across the loaded pads, one step each (default 1)");
    t.key("R",            "rename current pad (opens :rename <n>, 8 chars max)");
    t.key("e",            "open sampler editor for current pad");
    t.key("s",            "FX chain for drum track");
    t.key("+ / -",        "lengthen / shorten loop by one beat");
    t.key("m / M",        "shorten / lengthen THIS pad's own loop - a 7-step hat drifts against a 16-step kick");
    t.key(":pad-len",     "<n|off>  set the cursor pad's own loop length exactly (off = follow the pattern)");
    t.key("E",            "double loop length and copy its content");
    t.key("X",            "clear all steps on current pad");
    t.key("F",            "fill all steps on current pad");
    t.key("[ / ]",        "prev / next pattern variant (A–H)");
    t.key("N",            "new pattern variant (copy of current)");
    t.key("D",            "delete current pattern variant");
    t.key("d / y",        "operator: add a motion (h/l/H/L/0/w/b/g/G, counts work: d3l) to clear / yank that range");
    t.key("dd / yy",      "clear the cursor pad's row / yank the whole pattern");
    t.key("p",            "paste the latest yank (whole pattern or range, works across tracks)");
    t.key("(visual) y/d/p", "range yank / clear / paste (v or V to enter, hjkl to extend)");
    t.key(".",            "repeat last visual-mode range delete/paste at the cursor");

    t.taggedSection(.slicer_grid, "SLICER");
    t.key("",             "chop one loaded sample into slices, step-sequence the chops; each row");
    t.key("",             "  names its region - e opens the slice panel and its waveform");
    t.key(":load",        "[file.wav]  load a WAV as the shared clip (opens the file browser with no path)");
    t.key(":chop",        "[1-9]  chop at detected transients (sensitivity, default 5 - higher finds more)");
    t.key(":chop-random", "[n]  roll the dice: n uneven slices, boundaries picked at random (default 8)");
    t.key(":slice",       "<n>  equal-divide the loaded clip into n slices (1-64)");
    t.key(":spread",      "[semitones]  ramp pitch across the slices, one step each (default 1)");
    t.key(":bpm-sync",    "[clip-bpm]  warp the clip to project tempo, tune it to the project key");
    t.key("B",            "fit the clip to project tempo and key (:bpm-sync)");
    t.key("q / Q",        "transient chop / random 8-slice chop");
    t.key("A",            "cycle every slice: retrigger / one-shot / GATE");
    t.key("s / m",        "split cursor slice in half / merge it into the next (patterns follow)");
    t.key("h / l",        "move cursor left / right (one step)");
    t.key("H / L",        "move cursor left / right (one beat, coarse)");
    t.key("w / b",        "jump to next / previous beat boundary");
    t.key("j / k",        "move cursor down / up (slice)");
    t.key("J / K",        "jump a whole bank of 8 slices");
    t.key("0 / gg / gG",   "jump step cursor to start (0 or gg) / end (gG); counted 0 stays a digit");
    t.key("enter / n",    "toggle in place / place a slice and advance (count sets spacing)");
    t.key("",             "  with no clip loaded yet, enter opens the file browser instead");
    t.key("x",            "clear step at cursor");
    t.key("X / F",        "clear / fill the cursor slice's row");
    t.key("cv",           "cycle step velocity through presets (full/hard/mid/soft)");
    t.key("_ / =",        "step velocity down / up (fine, 1-127)");
    t.key("zg / zG",       "finer / coarser timing grid (1/4 through 1/128)");
    t.key("t / T",        "tune the step under the cursor down / up a semitone (±24, count-scaled)");
    t.key("cr",           "cycle the step into a roll (off/2/3/4/6/8 hits packed into the step)");
    t.key("%",            "cycle the step's fire chance (100/75/50/25/10%)");
    t.key("&",            "cycle the step's trig condition (1ST, FILL, 1:2, 2:4 … - ANDed with the chance)");
    t.key("!",            "flip the FILL switch every FILL/!FILL step reads - instant variation, no editing");
    t.key("; / '",        "drag the step early / late (±50% of a step) - per-hit feel, where < > swings every off-beat");
    t.key("",             "  cells: [x] plain, (x) tuned, <x> chance/condition/roll, {x} both");
    t.key("$",            "loop THIS slice over the cursor's step count - a 7-step hat drifts against a 16-step kick");
    t.key("",             "  ($ again on the same step puts the slice back on the pattern's length)");
    t.key("d / y",        "+motion: delete / yank a step range; dd clears the row, yy yanks the pattern");
    t.key("v / V",        "visual: a (slice, step) block, j/k grow it / visual line: every slice - y/d/p");
    t.key("p",            "paste the yanked range at the cursor step");
    t.key(".",            "repeat last range delete/paste at the cursor");
    t.key("a",            "preview current slice");
    t.key("i",            "insert mode: trigger slices on the qwerty piano (pitch wraps to slice count)");
    t.key("+ / -",        "lengthen / shorten loop by one beat");
    t.key("E",            "double loop length and copy its content");
    t.key("O",            "replace the grid with slices sequenced once in source order");
    t.key("( / )",        "nudge current slice's start earlier / later (region % follows)");
    t.key("{ / }",        "nudge current slice's end earlier / later");
    t.key("r",            "toggle current slice's reverse");
    t.key("< / >",        "swing (50% straight ... 75% hardest shuffle)");
    t.key("[ / ]",        "prev / next pattern variant (A–H; the drum grid's same pair)");
    t.key("N / D",        "new pattern variant (copy of current) / delete current");
    t.key("C",            "cycle current slice's choke group (grouped slices cut each other)");
    t.key("R",            "rename the loaded slicer clip (opens :rename)");
    t.key("e",            "edit the cursor slice in the full sampler editor (pitch, ADSR, gain, pan)");

    t.taggedSection(.sampler_editor, "SAMPLER EDITOR");
    t.key("j / k",        "select parameter");
    t.key("gg / gG",       "jump to first / last parameter");
    t.key("h / l",        "adjust value (fine)");
    t.key("H / L",        "adjust curve on attack/decay/release/fade params; coarse ×10 elsewhere");
    t.key("1–8",          "switch to pad/slice 1–8 within the current bank of 8");
    t.key("J / K",        "jump a whole bank of 8 pads/slices (same slot, next/prev bank)");
    t.key("a",            "audition current pad/slice");
    t.key("enter",        "with no sample loaded yet, open the file browser (nothing to edit until then)");
    t.key("s",            "FX chain for this track");
    t.key("p",            "note editor for this track - piano roll for a Sampler, step grid for a pad/slice");
    t.key("esc / e",      "back to the view that opened this editor (tracks, or the grid that sequences the pad/slice)");
    t.key(":load",        "[file.wav]  load a sample into the cursor pad or sampler track (omit the file to browse); sampler tracks auto-detect the clip's root note");
    t.key(":bpm-sync",    "[clip-bpm]  warp the clip to project tempo, tune it to the project key");
    t.key("B",            "fit the clip to project tempo and key (sampler/slice only)");

    // One editor, two instruments: Acoustic plays the bundled sample banks,
    // SoundFont plays presets out of a .sf2 the user loads.
    t.taggedSection(.soundfont_editor, "ACOUSTIC / SOUNDFONT EDITOR");
    t.key("j / k",        "select parameter (gain / pan / transpose / preset)");
    t.key("gg / gG",       "jump to first / last parameter");
    t.key("h / l",        "adjust value (fine); on PRESET, step to the prev/next preset in the font");
    t.key("H / L",        "adjust value (coarse ×10)");
    t.key("a",            "audition at the piano roll's last cursor pitch (or C4)");
    t.key("enter",        "SoundFont with no font loaded yet: open the .sf2 browser (nothing to edit until then)");
    t.key("s",            "FX chain for this track");
    t.key("p",            "piano roll for this track");
    t.key("f",            "preset picker - Acoustic lists the bundled banks, SoundFont every preset in the loaded font grouped by bank; / filters by name/bank/program");
    t.key("a (in picker)", "audition the highlighted bank/preset immediately; the switch commits either way");
    t.key("esc / e",      "back to the tracks view");
    t.key(":load",        "[file.sf2]  load a SoundFont into the cursor track (omit the file to browse; SoundFont tracks only)");
    t.key(":library", "<name>  load a bundled sample bank; f browses them (Acoustic tracks only)");
    t.key(":sf-preset",   "<bank> <program>  jump straight to a preset by its MIDI bank/program number");

    t.taggedSection(.synth_editor, "SYNTH EDITOR");
    t.key("tab",          "cycle subview: main params / mod matrix");
    t.key("z",            "focus the current MAIN/MOD section; z again restores the full grid");
    t.key("j / k",        "select parameter");
    t.key("gg / gG",       "jump to first / last parameter (within the current subview)");
    t.key("{ / }",        "prev / next section (within the current subview)");
    t.key("[ / ]",        "cycle the tabbed card the cursor is on (OSC A/B/C, LFO 1-3, FILTER 1/2, ENV 1-3), keeping the same row");
    t.key("h / l",        "adjust value (fine)");
    t.key("H / L",        "adjust curve on attack/decay/release params; coarse ×10 elsewhere");
    t.key("m",            "modulate the param under the cursor - points the first free MATRIX row at it and jumps there");
    t.key("w / b",        "move between fields inside a mod-matrix row (source / destination / depth)");
    t.key("p",            "open piano roll for this track");
    t.key("s",            "FX chain for this track");
    t.key("f",            "preset picker - factory + saved patches, / filters by name/tag/author, d deletes a save");
    t.key("a (in picker)", "audition the highlighted synth preset with C3; esc restores the original sound");
    t.key("/",            "fuzzy-search param names across both subviews, n / N repeat forward / backward");
    t.key(":synth-preset-save", "<name>  save the current params as a reusable preset");
    t.push(dim ++ "  ARP and ENV 1-3 sections sit in the main subview (j/k reaches them).", .{});
    t.push(dim ++ "  effects live on the track's own FX chain (s), not inside the synth.", .{});
    t.push(dim ++ "  MATRIX rows route a mod source (lfo 1-3/envs/velocity/keytrack/wheel/macros)", .{});
    t.push(dim ++ "  to any automatable param plus PITCH and AMP; depth is bipolar, same-dest", .{});
    t.push(dim ++ "  rows sum. MACRO knobs only act through matrix rows (mc1-mc4).", .{});

    t.taggedSection(.piano_roll, "PIANO ROLL");
    t.group("BASICS");
    t.key("h / l",        "move cursor left / right (one step)");
    t.key("H / L",        "move cursor left / right (one beat, coarse)");
    t.key("j / k",        "move cursor down / up (pitch)");
    t.key("J / K",        "move cursor down / up (one octave)");
    t.key("0 / gg / gG",   "jump cursor to start (0 or gg) / end (gG); counted 0 stays a digit");
    t.key("w / b",        "jump to the next / previous beat boundary");
    t.key("enter",        "toggle note; hold to shape pitch with j/k/J/K, length with h/l/H/L");
    t.key("n / N",        "enter note / rest, then advance by the default note length");
    t.key("x",            "delete note at cursor");
    t.key("M",            "grab note at cursor - h/l step, H/L beat, j/k pitch, J/K octave");
    t.key("Y",            "clone note at cursor with the same grab motions; esc drops");
    t.key("a",            "preview note at cursor (:audition sounds every j/k move too)");
    t.key("i",            "insert mode: play the qwerty piano (a-row/q-row, z/x octave)");
    t.key("(insert) space","start recording - clicks a one-bar count-in first if stopped");
    t.key("(insert) esc", "back to normal - while playing, notes recorded at the playhead");
    t.group("EDIT AND SHAPE");
    t.key("< / >",        "decrease / increase the selected field on the note at cursor (count-scaled)");
    t.key("; / '",        "micro-nudge note onset earlier / later by 1/128 note (count-scaled)");
    t.key("f / F",        "cycle what </> and the GUI lane edit: velocity, pan, fine tuning, release");
    t.key("e",            "open synth editor for this track");
    t.key("s",            "FX chain for this track");
    t.key("[ / ]",        "resize note at cursor, else set default length (count-scaled)");
    t.key("+ / -",        "lengthen / shorten loop (1 bar)");
    t.key("d / y",        "operator: add a motion (h/l/H/L/0/w/b/g/G, counts work: d3l, y2w) to clear / yank that range");
    t.key("dd / yy",      "clear the cursor pitch's row / yank the whole pattern");
    t.key("p",            "paste the latest yank (whole pattern or range, works across tracks)");
    t.key("v / V",        "visual: a (pitch, step) block, j/k grow it / visual line: every pitch - y/d/p");
    t.key("(visual) enter", "edit selected notes: hjkl moves them, HJKL by a beat / an octave; enter/esc stops");
    t.key("(edit) [] <> r i", "in that edit sub-mode: resize, velocity, reverse, invert - all count-scaled");
    t.key("(visual) + / -", "transpose the selected notes a semitone (stays selected - 12+ is an octave)");
    t.key("(visual) < / >", "slide the selected notes a step earlier / later (selection follows)");
    t.key("(visual) r",   "reverse the selected notes in time (retrograde; r again flips it back)");
    t.key("(visual) i",   "invert the selected notes around their pitch midpoint (i again folds it back)");
    t.key("(visual) o",   "jump to the selection's other end (also in drum/slicer/arrangement/automation)");
    t.key("[count]p",     "after a range yank: paste count copies back-to-back (3p tiles a bar three times)");
    t.key(".",            "repeat the last nudge, drag, or visual range delete/paste");
    t.key("cc",            "stamp a chord at cursor (:scale-aware; count inverts, 2cc = 2nd inversion)");
    t.key("c2 c3 c4 c6 c7 c9", "stamp sus2, triad, sus4, 6th, 7th, or 9th directly (count inverts)");
    t.key("ca cd c+",       "stamp add9, diminished, or augmented directly");
    t.key("C",             "stamp a 7th chord at cursor (also seeds the co/cO quality cycle)");
    t.key("co / cO",       "cycle chord quality (triad, 6th, 7th, 9th, 11th, 13th, sus2, sus4, add9, dim, aug), re-stamped in place");
    t.key("cr / cR",       "cycle chord voicing (closed, drop2, open), re-stamped in place");
    t.key("T",            "toggle grid: straight 1/16 <-> 1/16 triplet");
    t.key("zg / zG",       "finer / coarser timing grid (1/4 through 1/128)");
    t.key(":clear",       "erase all notes in the pattern");
    t.key(":scale",       "[<root> [<type>]|off]  scale highlight + chord-stamp key");
    t.key(":tuning",      "[<name> [<root>]]  temperament synths play in: equal, just_major, pythagorean, meantone_quarter, werckmeister3, kirnberger3");
    t.key(":snap-scale",  "[<root> [<type>]]  pull every off-scale note onto the nearest tone of that scale");

    t.taggedSection(.arrangement, "ARRANGEMENT");
    t.key("h / l",        "move cursor left / right (one grid cell)");
    t.key("H / L",        "move cursor left / right (4 cells)");
    t.key("w / b",        "jump to next / previous bar line");
    t.key("B / W",        "jump to previous / next clip edge on current lane");
    t.key("0",            "jump cursor to bar 0 (a count first makes it a digit instead: 10l)");
    t.key("gG",           "jump to the song's end (gg = bar 0; a count first is dropped)");
    t.key("j / k",        "move between track lanes");
    t.key("enter",        "stamp the live pattern as a clip - HOLD it and h/l resize the new clip");
    t.key("e",            "edit melodic clip in the piano roll (edits save into the clip)");
    t.key(":load",        "[file.wav]  load a WAV onto a sampler track and stamp it whole at the cursor bar");
    t.key(":import-audio", "<file>  drop an audio file straight on the cursor lane (an empty track becomes an Audio track)");
    t.key("[ / ]",        "cycle drum/slicer pattern variant to stamp");
    t.key("x",            "delete clip at cursor");
    t.key("y / p",        "yank / paste clip (matching track kind)");
    t.key("v / V",        "visual: lane block / every lane - y/d delete, D remove time, p/P overwrite/insert");
    t.key("(visual) =",   "set the A/B loop from selected time");
    t.key("< / >",        "move clip left / right by a bar");
    t.key("- / +",        "edge-resize clip length by a bar (content loops to fill it)");
    t.key(".",            "repeat the last clip move / resize or visual range delete/paste");
    t.key("( / )",        "set loop start / end at cursor bar");
    t.key("=",            "toggle A/B loop on/off");
    t.key(":punch",       "[on|off]  record only between enabled A/B bounds");
    t.key(":monitor",     "[off|auto|on]  input monitoring mode");
    t.key(":take",        "[next|prev]  cycle the alternate recordings on the audio clip at cursor");
    t.key(":comp",        "<take> <start-beat> <end-beat>  splice alternate take range");
    t.key(":crossfade",   "fade the two overlapping audio layers at cursor into each other");
    t.key(":consolidate", "bake the cursor audio clip's gain, fades, stretch and reverse into one source");
    t.key("gs",           "play from cursor bar");
    t.key("T",            "toggle song / pattern mode (manual override; view switches while the");
    t.key("",             "  transport is stopped set it for you: arrangement = song, tracks (or a");
    t.key("",             "  pattern editor from tracks) = pattern; playback is never interrupted)");
    t.key("zg / zG",       "finer / coarser timing grid (1/4 through 1/128)");
    t.key("a",            "open gain/pan automation editor for the clip at cursor");
    t.key("/",            "fuzzy-search lane (track) names, n / N repeat forward / backward");
    t.key("{ / }",        "jump to previous / next named section");
    t.key("s",            "select current named section across every lane");
    t.key("S",            "split the clip at cursor in two, removing nothing (x and d cut material out)");
    t.key(":section",     "<name>  add or rename a section at cursor; :section-del removes it");
    t.key("tab",          "back to the tracks view");

    t.taggedSection(.automation, "AUTOMATION  (per-clip breakpoints - opened via 'a' in the arrangement)");
    t.key("h / l",        "move cursor along the clip's beat axis");
    t.key("H / L",        "move cursor by a bar");
    t.key("j / k",        "nudge the value at cursor (fine step) - adds a point if none exists");
    t.key("J / K",        "nudge the value at cursor (coarse step)");
    t.key("x",            "delete the point at cursor exactly");
    t.key("c",            "cycle the ramp leaving the point at cursor: linear -> hold (step) -> ease (S-curve)");
    t.key("0 / gg / gG",   "jump cursor to start (0 or gg) / end (gG); counted 0 stays a digit");
    t.key("w / b",        "jump to the next / previous beat start");
    t.key("d / y",        "operator: add a motion (h/l/H/L/0/w/b/g/G, counts work: d3l) to clear / yank that range");
    t.key("dd / yy",      "clear / yank the whole curve");
    t.key("v / V",        "visual mode: select a step range on the current curve - y/d/p (both keys are equivalent)");
    t.key(".",            "repeat the last nudge or visual range delete/paste");
    t.key("tab",          "cycle gain -> pan -> instrument params already on this clip -> gain");
    t.key("p",            "pick an instrument param to automate (synth ~30, sampler 9 continuous params)");
    t.key("P",            "paste the latest range yank at the cursor (p is taken by the param picker above)");
    t.key("esc",          "back to the arrangement");

    t.taggedSection(.spectrum, "FX CHAIN  (same chain view for a track, the master bus, or a group)");
    t.key("",             "chains start empty; build them unit by unit, in any order, duplicates allowed");
    t.key("a",            "insert an effect after the focused slot (opens the FX picker); / filters it by name, g/G jumps first/last");
    t.key("A",            "add an automation lane for the selected effect parameter");
    t.key("x",            "remove the focused unit");
    t.key("y / P",        "yank / paste the focused unit (works across track, group, and master chains)");
    t.key("< / >",        "move the focused unit one slot left / right along the chain");
    t.key("b",            "bypass toggle: the unit keeps its settings but the audio skips it");
    t.key("tab / ] / [",  "walk slot focus along the chain (an EQ unit's editor doubles as the spectrum analyzer)");
    t.key("j / k",        "select a param within the focused unit");
    t.key("h / l",        "decrease / increase the selected param (fine step)");
    t.key("H / L",        "decrease / increase the selected param (coarse step)");
    t.key("",             "EQ gets its own scheme instead: h/l picks which of its 8 bands is in view (H/L");
    t.key("",             "  jump 4 at a time), enter opens that band's kind/freq/q/gain-or-slope submenu");
    t.key("",             "  (j/k picks the field there, h/l nudges it, esc backs out to band-select first)");
    t.key("",             "  a band's 'kind' row: h/l cycles peak/lowpass/highpass/lowshelf/highshelf/notch/");
    t.key("",             "  tiltshelf (a symmetric Baxandall tilt around the corner freq); once it's a");
    t.key("",             "  filter kind the last row becomes 'slope' (12/24/36/48dB/oct) instead of 'gain'");
    t.key("",             "  further rows: 'solo' isolates just that band's frequency region to audition");
    t.key("",             "  it; 'stereo' cycles stereo/mid/side (filter only the sum or difference signal);");
    t.key("",             "  'dyn' turns the band into a dynamic EQ - above 'dyn thr' the gain moves toward");
    t.key("",             "  gain+'dyn amt' (attack/release smoothed), like a compressor for one frequency");
    t.key("g",            "EQ only: toggle auto-gain (estimates the curve's average level shift and");
    t.key("",             "  compensates output so a big boost/cut doesn't also change the overall volume)");
    t.key("p",            "EQ only: flip the spectrum analyzer between pre-EQ and post-EQ (default)");
    t.key("f",            "EQ only: freeze the spectrum analyzer on its current snapshot for A/B comparison");
    t.key("",             "a compressor's 'sidechain' param: h/l cycles none/track N - its envelope then");
    t.key("",             "  detects from track N's signal instead of its own input (duck a bass off a kick)");
    t.key("",             "  'scpad' (next param): h/l cycles none/pad N - narrows detection to one drum pad");
    t.key("",             "  in that track (e.g. just the kick, not the whole kit) instead of its whole mix");
    t.key("",             "Multiband: 2 crossover splits (low/mid/high), each band its own thresh/ratio/");
    t.key("",             "  makeup; 'style' h/l toggles classic (downward only) <-> OTT (also squashes");
    t.key("",             "  quiet signal UP toward the threshold); 'mix' blends dry <-> fully processed");
    t.key("",             "OTT: the multiband squash pre-tuned to the famous preset, 4 params only -");
    t.key("",             "  depth (dry<->wet), time (attack+release speed), in/out gain; reach for the");
    t.key("",             "  full Multiband unit instead when you want the crossovers or per-band control");
    t.key("- / +",        "group chain only: bus fader for the whole submix, post-FX (also :group-gain)");

    t.taggedSection(.file_browser, "FILE BROWSER  (netrw-style; opens on :edit or :load with no path)");
    t.key("j / k",        "move cursor");
    t.key("enter/l/space", "open directory / pick file");
    t.key("h / backspace","up to the parent directory");
    t.key("g / G",        "jump to first / last entry");
    t.key("~",            "jump to $HOME");
    t.key("/",            "fuzzy-search filenames, n / N repeat forward / backward - matches are highlighted");
    t.key("v",            "drum pad loads only: start a multi-file selection - j/k/g/G extend it");
    t.key("enter (visual)","load every selected file into consecutive pads from the cursor pad up (vG enter takes the whole folder)");
    t.key("a",            "audition the file under the cursor - plays off-mixer, picks nothing");
    t.key("b",            "bookmark / unbookmark the entry under the cursor (persists across sessions)");
    t.key("B",            "open the bookmark list - enter/l jumps, d removes, esc/q back");
    t.key("esc / q",      "cancel back to the previous view");
    // zig fmt: on

    if (keymaps.len > 0) {
        t.section("USER KEYMAPS  (from init.lua; modes n/i/v, then the keys)");
        for (keymaps) |*km| {
            var mode_buf: [3]u8 = undefined;
            var lhs_buf: [48]u8 = undefined;
            var col_buf: [64]u8 = undefined;
            const col = std.fmt.bufPrint(&col_buf, "{s} {s}", .{ km.modeText(&mode_buf), km.lhsText(&lhs_buf) }) catch continue;
            if (km.desc().len > 0) {
                t.key(col, km.desc());
            } else if (km.rhs == .command) {
                t.push(acc ++ "  {s: <16}" ++ rst ++ dim ++ ":{s}", .{ col, km.cmd() });
            } else {
                t.key(col, "lua function");
            }
        }
    }
}

/// Line offset where `section`'s content starts, so opening help from a
/// given view can land on its own keybindings instead of always the top.
/// `null` (views with no dedicated section, e.g. the instrument picker) opens
/// on COMMANDS as before.
pub fn scrollForSection(section: ?Section, cmds: []const cmd_mod.Def, keymaps: []const config_mod.Keymap) usize {
    var t = HelpText{};
    buildHelp(&t, cmds, keymaps);
    return if (section) |s| t.section_start.get(s) else 0;
}

/// Scroll target of the section before / after the one `scroll` sits in -
/// the help view's `{` / `}`. Lands on the section's blank spacer (the line
/// `scrollForSection` records), so the title renders one row into the
/// window instead of flush against the previous section's last key.
pub fn sectionScroll(cmds: []const cmd_mod.Def, keymaps: []const config_mod.Keymap, scroll: usize, dir: i8) usize {
    var t = HelpText{};
    buildHelp(&t, cmds, keymaps);
    const cur = t.sectionLineAt(scroll +| 1) orelse return 0;
    if (dir > 0) return (t.nextSectionLine(cur) orelse cur) -| 1;
    // Backwards from inside a section returns to that section's own top
    // first, and only steps to the previous one once already parked there -
    // vim's paragraph motion, and it keeps a long section's title reachable
    // from its middle in a single press.
    // Saturating: `G` parks the scroll at maxInt until the next draw clamps
    // it, so a `{` in between must not overflow here.
    if (scroll +| 1 > cur) return cur -| 1;
    return (t.sectionLineAt(cur -| 1) orelse cur) -| 1;
}

test "help section jumps land on each section's spacer line" {
    const commands = @import("commands.zig");
    var t = HelpText{};
    buildHelp(&t, commands.cmds, &.{});
    const first = t.sectionLineAt(0).?;
    const second = t.nextSectionLine(first).?;
    // From the top: `}` steps to the next section, `{` cannot go past 0.
    try std.testing.expectEqual(second - 1, sectionScroll(commands.cmds, &.{}, 0, 1));
    try std.testing.expectEqual(@as(usize, 0), sectionScroll(commands.cmds, &.{}, 0, -1));
    // Parked inside the second section, `{` returns to its own title first.
    try std.testing.expectEqual(second - 1, sectionScroll(commands.cmds, &.{}, second + 3, -1));
    // Parked on it, `{` steps back to the first section.
    try std.testing.expectEqual(first -| 1, sectionScroll(commands.cmds, &.{}, second - 1, -1));
    // `G` leaves the scroll at maxInt until the next draw clamps it; both
    // jumps have to survive that unclamped value.
    const huge = std.math.maxInt(usize);
    try std.testing.expect(sectionScroll(commands.cmds, &.{}, huge, -1) < t.count);
    try std.testing.expect(sectionScroll(commands.cmds, &.{}, huge, 1) < t.count);
}

test "section rows are the only bold lines, and their titles strip clean" {
    const commands = @import("commands.zig");
    var t = HelpText{};
    buildHelp(&t, commands.cmds, &.{});
    const first = t.sectionLineAt(0).?;
    try std.testing.expectEqualStrings("COMMANDS", sectionTitle(t.line(first)));
    // A key row inside that section reports the section it belongs to.
    try std.testing.expectEqual(first, t.sectionLineAt(first + 2).?);
}

pub const Viewport = struct { off: usize, end: usize, max_scroll: usize };

pub fn viewport(count: usize, visible: usize, scroll: *usize) Viewport {
    const max_scroll = count -| visible;
    scroll.* = @min(scroll.*, max_scroll);
    return .{ .off = scroll.*, .end = @min(scroll.* + visible, count), .max_scroll = max_scroll };
}

test "help viewport clamps stored scroll to last full window" {
    var scroll: usize = 99;
    const view = viewport(20, 6, &scroll);
    try std.testing.expectEqual(@as(usize, 14), scroll);
    try std.testing.expectEqual(Viewport{ .off = 14, .end = 20, .max_scroll = 14 }, view);
}

/// Match `pattern` against the help's rendered lines, starting one line
/// past `start` in `dir` (+1 forward, -1 backward) and wrapping around the
/// whole text - the same walk App.searchTracks/searchBrowser do over their
/// lists. Case-insensitive SUBSTRING match, not the fuzzy subsequence the
/// other searches use: against 70-char prose lines a subsequence is so
/// loose that "sidechain" matches "edit track (synth or drum grid)…" long
/// before the actual sidechain line. Fuzzy earns its keep on short names;
/// prose needs the stricter rule.
pub fn search(cmds: []const cmd_mod.Def, keymaps: []const config_mod.Keymap, pattern: []const u8, start: usize, dir: i64) ?usize {
    var t = HelpText{};
    buildHelp(&t, cmds, keymaps);
    if (t.count == 0) return null;
    const n: i64 = @intCast(t.count);
    const anchor: i64 = @intCast(@min(start, t.count - 1));
    var step: i64 = 1;
    while (step <= n) : (step += 1) {
        const idx: usize = @intCast(@mod(anchor + dir * step, n));
        var plain_buf: [512]u8 = undefined;
        // Search matches visible bytes only, never the raw line - otherwise a
        // pattern could "match" color-code bytes the user can't see.
        if (std.ascii.indexOfIgnoreCase(ansi.stripAnsi(t.line(idx), &plain_buf), pattern) != null) return idx;
    }
    return null;
}

test "help search wraps forward from the end; no match is null" {
    const commands = @import("commands.zig");
    // "master volume" lives in WORKSPACE BASICS near the top, so an
    // anchor past the last line (clamped there) only finds it by wrapping.
    try std.testing.expect(search(commands.cmds, &.{}, "master volume", 100000, 1) != null);
    try std.testing.expectEqual(@as(?usize, null), search(commands.cmds, &.{}, "zzqqxxjj", 0, 1));
}

test "help text fits its buffers - nothing silently truncated" {
    const commands = @import("commands.zig");
    var t = HelpText{};
    buildHelp(&t, commands.cmds, &.{});
    try std.testing.expect(!t.truncated);
    // Early warning well before the hard cap: growing content should bump
    // the buffer deliberately, not creep up on the blank-lines cliff again.
    try std.testing.expect(t.len + 8192 <= t.buf.len);
    try std.testing.expect(t.count + 64 <= t.ends.len);
}

test "help lists mnemonic commands and omits compatibility aliases" {
    const commands = @import("commands.zig");
    var t = HelpText{};
    buildHelp(&t, commands.cmds, &.{});
    const text = t.buf[0..t.len];
    try std.testing.expect(std.mem.indexOf(u8, text, ":write") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  :w             ") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  :save          ") == null);
}

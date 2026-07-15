//! Modal input engine — the heart of the keyboard-first workflow.
//!
//! Modeled on vim: normal mode navigates and drives the transport,
//! insert mode turns the keyboard into a piano, visual mode selects,
//! command mode takes ex-style commands, search mode takes a `/` fuzzy
//! pattern (n/N repeat it — see App.searchTracks/searchBrowser, the only
//! two views with something to search). This layer is pure state
//! machine — no terminal, no UI — so every binding is unit-testable
//! and any frontend (TUI, GUI) can sit on top.

const std = @import("std");

pub const Mode = enum { normal, insert, visual, command, search };

pub const Key = union(enum) {
    char: u8,
    escape,
    enter,
    backspace,
    /// Arrow keys, decoded from terminal CSI sequences as their own variants
    /// (not aliased to hjkl chars) so command mode can tell a real arrow
    /// press from someone typing 'h'/'j'/'k'/'l' into a command. The
    /// frontend (App.handleKey) aliases them to hjkl outside command mode,
    /// matching the vim convention that arrows are a motion synonym.
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    /// Command-mode line-editing: jump to the start/end of the buffer.
    /// In normal mode (handleNormal) home/end instead seek the playhead to
    /// the start/end of the content — a `gg`/`G`-alike that stays reachable
    /// even in views (piano roll, drum grid, arrangement) where `g`/`G` are
    /// already claimed for cursor motion.
    home,
    end,
    /// (command mode only) delete the word behind the cursor.
    ctrl_w,
    /// Vim's canonical redo key, alongside `U` — handled by whichever view
    /// (App.handleKey/editors/*.zig) tracks undo history; no meaning in
    /// command mode (see handleCommand).
    ctrl_r,
    /// Command-mode completion (App.handleKey completes the typed command
    /// name against the command table); ignored elsewhere.
    tab,
    /// Intercepted by the frontend (quit); modal layer ignores it.
    ctrl_c,
    /// Intercepted by App.handleKey before it reaches the modal layer at all
    /// (mouse events aren't part of the vim state machine — they're routed
    /// straight to the active view's own handler). Still a Key variant so
    /// terminal.decode() can hand them back through the same buffer as
    /// keyboard input.
    mouse: MouseEvent,
};

pub const MouseButton = enum { left, middle, right, none };
pub const MouseKind = enum { press, release, drag, scroll_up, scroll_down };

/// A decoded SGR mouse report. Coordinates are 0-based terminal cells
/// (SGR's own Cx/Cy are 1-based; terminal.decode subtracts 1).
pub const MouseEvent = struct {
    x: u16,
    y: u16,
    button: MouseButton,
    kind: MouseKind,
    ctrl: bool = false,
    shift: bool = false,
};

pub const Action = union(enum) {
    none,
    mode_changed: Mode,
    move: Move,
    goto_start,
    goto_end,
    toggle_play,
    toggle_mute,
    toggle_solo,
    octave_down,
    octave_up,
    /// Insert-mode key mapped through the piano layout.
    note: struct { pitch: u7 },
    /// Slice is valid until command mode is entered again.
    command_submit: []const u8,
    /// A submitted `/` search pattern. Empty means "repeat the last search"
    /// (vim's `//` convention) — see App.applyAction. Slice is valid until
    /// search mode is entered again (same buffer as command_submit).
    search_submit: []const u8,
    /// Signed dB steps to apply to master volume (+n = louder, −n = quieter).
    volume_delta: i32,

    pub const Move = struct { dx: i32 = 0, dy: i32 = 0 };
};

/// Piano-style layout: a-row = white notes, q-row = black notes.
/// z = octave down, x = octave up. With octave 4, 'a' = middle C (MIDI 60).
///
///   q  w     r  t  y     i  o     p
///  C# D#    F# G# A#    C# D#    F#
///   a  s  d  f  g  h  j  k  l  ;
///   C  D  E  F  G  A  B  C  D  E
pub fn noteForChar(c: u8, octave: u4) ?u7 {
    const semi: u8 = switch (c) {
        // a-row — white notes
        // zig fmt: off
        'a' => 0,   // C
        's' => 2,   // D
        'd' => 4,   // E
        'f' => 5,   // F
        'g' => 7,   // G
        'h' => 9,   // A
        'j' => 11,  // B
        'k' => 12,  // C'
        'l' => 14,  // D'
        ';' => 16,  // E'
        // q-row — black notes (e and u are gaps: E-F and B-C have no black key)
        'q' => 1,   // C#
        'w' => 3,   // D#
        'r' => 6,   // F#
        't' => 8,   // G#
        'y' => 10,  // A#
        'i' => 13,  // C#'
        'o' => 15,  // D#'
        'p' => 18,  // F#'
        // zig fmt: on
        else => return null,
    };
    const midi = (@as(u8, octave) + 1) * 12 + semi;
    if (midi > 127) return null;
    return @intCast(midi);
}

pub const ModalInput = struct {
    mode: Mode = .normal,
    /// vim-style count prefix, e.g. the 3 in "3j".
    count: u32 = 0,
    /// First key of a multi-key sequence, e.g. the first g of "gg".
    pending: ?u8 = null,
    octave: u4 = 4,
    cmd_buf: [max_cmd_len]u8 = undefined,
    cmd_len: usize = 0,
    /// Insertion point within `cmd_buf[0..cmd_len]`. Chars insert and
    /// backspace deletes at this position rather than only at the end.
    cmd_cursor: usize = 0,

    pub const max_cmd_len = 64;

    pub fn handle(self: *ModalInput, key: Key) Action {
        return switch (self.mode) {
            .normal, .visual => self.handleNormal(key),
            .insert => self.handleInsert(key),
            .command => self.handleCommand(key),
            .search => self.handleSearch(key),
        };
    }

    fn setMode(self: *ModalInput, mode: Mode) Action {
        self.mode = mode;
        self.count = 0;
        self.pending = null;
        return .{ .mode_changed = mode };
    }

    /// Consumes the accumulated count (default 1).
    pub fn takeCount(self: *ModalInput) i32 {
        const n: u32 = if (self.count == 0) 1 else self.count;
        self.count = 0;
        return @intCast(n);
    }

    fn appendCountDigit(self: *ModalInput, digit: u32) void {
        const limit: u32 = std.math.maxInt(i32);
        if (self.count > (limit - digit) / 10) {
            self.count = limit;
        } else {
            self.count = self.count * 10 + digit;
        }
    }

    fn handleNormal(self: *ModalInput, key: Key) Action {
        const c = switch (key) {
            .char => |c| c,
            .escape => {
                self.count = 0;
                self.pending = null;
                if (self.mode == .visual) return self.setMode(.normal);
                return .none;
            },
            .home => return .goto_start,
            .end => return .goto_end,
            else => return .none,
        };

        if (self.pending) |p| {
            self.pending = null;
            if (p == 'g' and c == 'g') return .goto_start;
            return .none;
        }

        switch (c) {
            '1'...'9' => {
                self.appendCountDigit(c - '0');
                return .none;
            },
            '0' => {
                if (self.count > 0) self.appendCountDigit(0);
                return .none;
            },
            'h' => return .{ .move = .{ .dx = -self.takeCount() } },
            'l' => return .{ .move = .{ .dx = self.takeCount() } },
            'j' => return .{ .move = .{ .dy = self.takeCount() } },
            'k' => return .{ .move = .{ .dy = -self.takeCount() } },
            'g' => {
                self.pending = 'g';
                return .none;
            },
            'G' => return .goto_end,
            'i' => return self.setMode(.insert),
            ':' => {
                self.cmd_len = 0;
                self.cmd_cursor = 0;
                return self.setMode(.command);
            },
            '/' => {
                self.cmd_len = 0;
                self.cmd_cursor = 0;
                return self.setMode(.search);
            },
            ' ' => return .toggle_play,
            'm' => return .toggle_mute,
            'S' => return .toggle_solo,
            '[' => return .{ .volume_delta = -self.takeCount() },
            ']' => return .{ .volume_delta = self.takeCount() },
            else => return .none,
        }
    }

    fn handleInsert(self: *ModalInput, key: Key) Action {
        const c = switch (key) {
            .char => |c| c,
            .escape => return self.setMode(.normal),
            else => return .none,
        };
        switch (c) {
            'z' => {
                if (self.octave > 0) self.octave -= 1;
                return .octave_down;
            },
            'x' => {
                if (self.octave < 8) self.octave += 1;
                return .octave_up;
            },
            // Not a piano key (space is never mapped in noteForChar, unlike
            // z/x carved out above) — free to double as the same transport
            // toggle normal mode uses, so starting/stopping playback (and,
            // in the piano roll, arming a recording) doesn't need dropping
            // out of insert mode first.
            ' ' => return .toggle_play,
            else => {
                if (noteForChar(c, self.octave)) |pitch| {
                    return .{ .note = .{ .pitch = pitch } };
                }
                return .none;
            },
        }
    }

    fn handleCommand(self: *ModalInput, key: Key) Action {
        switch (key) {
            .escape => return self.setMode(.normal),
            .enter => {
                self.mode = .normal;
                return .{ .command_submit = self.cmd_buf[0..self.cmd_len] };
            },
            else => return self.editLine(key),
        }
    }

    /// Search mode's `.escape`/`.enter` mirror command mode's exactly (cancel
    /// vs. submit); everything else is the same line-editing, hence sharing
    /// `editLine` rather than duplicating it.
    fn handleSearch(self: *ModalInput, key: Key) Action {
        switch (key) {
            .escape => return self.setMode(.normal),
            .enter => {
                self.mode = .normal;
                return .{ .search_submit = self.cmd_buf[0..self.cmd_len] };
            },
            else => return self.editLine(key),
        }
    }

    /// Shared readline-style editing for the `:` and `/` prompts: insert/
    /// delete chars at the cursor, move it, ctrl-w word-delete. `.escape`/
    /// `.enter` are mode-specific (submit vs. cancel differently) and always
    /// intercepted by the caller before this is reached.
    fn editLine(self: *ModalInput, key: Key) Action {
        switch (key) {
            .backspace => {
                if (self.cmd_cursor == 0) return .none;
                std.mem.copyForwards(
                    u8,
                    self.cmd_buf[self.cmd_cursor - 1 .. self.cmd_len - 1],
                    self.cmd_buf[self.cmd_cursor..self.cmd_len],
                );
                self.cmd_len -= 1;
                self.cmd_cursor -= 1;
                return .none;
            },
            .char => |c| {
                if (self.cmd_len >= max_cmd_len) return .none;
                std.mem.copyBackwards(
                    u8,
                    self.cmd_buf[self.cmd_cursor + 1 .. self.cmd_len + 1],
                    self.cmd_buf[self.cmd_cursor..self.cmd_len],
                );
                self.cmd_buf[self.cmd_cursor] = c;
                self.cmd_len += 1;
                self.cmd_cursor += 1;
                return .none;
            },
            .arrow_left => {
                self.cmd_cursor -|= 1;
                return .none;
            },
            .arrow_right => {
                if (self.cmd_cursor < self.cmd_len) self.cmd_cursor += 1;
                return .none;
            },
            .home => {
                self.cmd_cursor = 0;
                return .none;
            },
            .end => {
                self.cmd_cursor = self.cmd_len;
                return .none;
            },
            // bash/readline ctrl-w: eat trailing spaces, then the word
            // behind the cursor.
            .ctrl_w => {
                var i = self.cmd_cursor;
                while (i > 0 and self.cmd_buf[i - 1] == ' ') i -= 1;
                while (i > 0 and self.cmd_buf[i - 1] != ' ') i -= 1;
                const removed = self.cmd_cursor - i;
                std.mem.copyForwards(
                    u8,
                    self.cmd_buf[i .. self.cmd_len - removed],
                    self.cmd_buf[self.cmd_cursor..self.cmd_len],
                );
                self.cmd_len -= removed;
                self.cmd_cursor = i;
                return .none;
            },
            // Handled by App.handleKey before it reaches here (history
            // recall on up/down, tab-completion, mouse routing); nothing
            // left to do here. `.escape`/`.enter` never actually reach this
            // switch (handleCommand/handleSearch intercept them first) but
            // still need an arm for exhaustiveness.
            .escape, .enter, .arrow_up, .arrow_down, .tab, .ctrl_c, .ctrl_r, .mouse => return .none,
        }
    }
};

fn press(input: *ModalInput, keys: []const u8) Action {
    var last: Action = .none;
    for (keys) |c| last = input.handle(.{ .char = c });
    return last;
}

test "counts multiply motions" {
    var input: ModalInput = .{};
    try std.testing.expectEqual(Action{ .move = .{ .dy = 3 } }, press(&input, "3j"));
    try std.testing.expectEqual(Action{ .move = .{ .dy = 1 } }, press(&input, "j"));
    try std.testing.expectEqual(Action{ .move = .{ .dx = -12 } }, press(&input, "12h"));
}

test "multi-key sequences" {
    var input: ModalInput = .{};
    try std.testing.expectEqual(Action.none, press(&input, "g"));
    try std.testing.expectEqual(Action.goto_start, press(&input, "g"));
    try std.testing.expectEqual(Action.goto_end, press(&input, "G"));
}

test "insert mode plays the keyboard as a piano" {
    var input: ModalInput = .{};
    try std.testing.expectEqual(Action{ .mode_changed = .insert }, press(&input, "i"));
    try std.testing.expectEqual(Action{ .note = .{ .pitch = 60 } }, press(&input, "a")); // C4 (middle C)
    try std.testing.expectEqual(Action{ .note = .{ .pitch = 64 } }, press(&input, "d")); // E4
    try std.testing.expectEqual(Action{ .note = .{ .pitch = 72 } }, press(&input, "k")); // C5
    try std.testing.expectEqual(Action{ .note = .{ .pitch = 61 } }, press(&input, "q")); // C#4 (black key)
    try std.testing.expectEqual(Action{ .note = .{ .pitch = 66 } }, press(&input, "r")); // F#4
    try std.testing.expectEqual(Action.octave_down, press(&input, "z")); // z = oct down
    try std.testing.expectEqual(Action{ .note = .{ .pitch = 48 } }, press(&input, "a")); // C3
    try std.testing.expectEqual(Action.octave_up, press(&input, "x")); // x = oct up
    try std.testing.expectEqual(Action{ .mode_changed = .normal }, input.handle(.escape));
}

test "space toggles the transport in insert mode too, without leaving it" {
    var input: ModalInput = .{};
    _ = press(&input, "i");
    try std.testing.expectEqual(Action.toggle_play, press(&input, " "));
    try std.testing.expectEqual(Mode.insert, input.mode); // still playable afterward
    try std.testing.expectEqual(Action{ .note = .{ .pitch = 60 } }, press(&input, "a"));
}

test "command mode collects text until enter" {
    var input: ModalInput = .{};
    try std.testing.expectEqual(Action{ .mode_changed = .command }, press(&input, ":"));
    _ = press(&input, "wqx");
    _ = input.handle(.backspace);
    const action = input.handle(.enter);
    try std.testing.expectEqualStrings("wq", action.command_submit);
    try std.testing.expectEqual(Mode.normal, input.mode);
}

test "command mode: left/right move the cursor, chars and backspace act at it" {
    var input: ModalInput = .{};
    _ = press(&input, ":");
    _ = press(&input, "bpm"); // "bpm", cursor at 3
    _ = input.handle(.arrow_left);
    _ = input.handle(.arrow_left); // cursor at 1, between 'b' and 'pm'
    _ = press(&input, "X"); // insert mid-line -> "bXpm"
    try std.testing.expectEqualStrings("bXpm", input.cmd_buf[0..input.cmd_len]);

    _ = input.handle(.backspace); // deletes the 'X' just inserted -> "bpm"
    try std.testing.expectEqualStrings("bpm", input.cmd_buf[0..input.cmd_len]);
    try std.testing.expectEqual(@as(usize, 1), input.cmd_cursor);

    // Right past the end clamps instead of overflowing.
    for (0..10) |_| _ = input.handle(.arrow_right);
    try std.testing.expectEqual(@as(usize, 3), input.cmd_cursor);
    // Left past the start clamps at 0.
    for (0..10) |_| _ = input.handle(.arrow_left);
    try std.testing.expectEqual(@as(usize, 0), input.cmd_cursor);
}

test "command mode: home/end jump the cursor, ctrl-w deletes the word behind it" {
    var input: ModalInput = .{};
    _ = press(&input, ":");
    _ = press(&input, "gain 1 -6");
    _ = input.handle(.home);
    try std.testing.expectEqual(@as(usize, 0), input.cmd_cursor);
    _ = input.handle(.end);
    try std.testing.expectEqual(@as(usize, 9), input.cmd_cursor);

    _ = input.handle(.ctrl_w); // deletes "-6" -> "gain 1 "
    try std.testing.expectEqualStrings("gain 1 ", input.cmd_buf[0..input.cmd_len]);
    _ = input.handle(.ctrl_w); // eats the trailing space, then "1" -> "gain "
    try std.testing.expectEqualStrings("gain ", input.cmd_buf[0..input.cmd_len]);
}

test "space toggles transport, escape cancels count" {
    var input: ModalInput = .{};
    try std.testing.expectEqual(Action.toggle_play, press(&input, " "));
    try std.testing.expectEqual(Action.toggle_mute, press(&input, "m"));
    try std.testing.expectEqual(Action.toggle_solo, press(&input, "S"));
    _ = press(&input, "42");
    _ = input.handle(.escape);
    try std.testing.expectEqual(Action{ .move = .{ .dy = 1 } }, press(&input, "j"));
}

test "normal mode count saturates without overflowing" {
    var input: ModalInput = .{};
    for (0..32) |_| _ = input.handle(.{ .char = '9' });

    try std.testing.expectEqual(
        Action{ .move = .{ .dx = std.math.maxInt(i32) } },
        input.handle(.{ .char = 'l' }),
    );
    try std.testing.expectEqual(@as(u32, 0), input.count);
}

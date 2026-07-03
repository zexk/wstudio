//! Modal input engine — the heart of the keyboard-first workflow.
//!
//! Modeled on vim: normal mode navigates and drives the transport,
//! insert mode turns the keyboard into a piano, visual mode selects,
//! command mode takes ex-style commands. This layer is pure state
//! machine — no terminal, no UI — so every binding is unit-testable
//! and any frontend (TUI, GUI) can sit on top.

const std = @import("std");

pub const Mode = enum { normal, insert, visual, command };

pub const Key = union(enum) {
    char: u8,
    escape,
    enter,
    backspace,
    /// Intercepted by the frontend (quit); modal layer ignores it.
    ctrl_c,
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

    pub const max_cmd_len = 64;

    pub fn handle(self: *ModalInput, key: Key) Action {
        return switch (self.mode) {
            .normal, .visual => self.handleNormal(key),
            .insert => self.handleInsert(key),
            .command => self.handleCommand(key),
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

    fn handleNormal(self: *ModalInput, key: Key) Action {
        const c = switch (key) {
            .char => |c| c,
            .escape => {
                self.count = 0;
                self.pending = null;
                if (self.mode == .visual) return self.setMode(.normal);
                return .none;
            },
            else => return .none,
        };

        if (self.pending) |p| {
            self.pending = null;
            if (p == 'g' and c == 'g') return .goto_start;
            return .none;
        }

        switch (c) {
            '1'...'9' => {
                self.count = self.count * 10 + (c - '0');
                return .none;
            },
            '0' => {
                if (self.count > 0) self.count *= 10;
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
                return self.setMode(.command);
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
            .backspace => {
                if (self.cmd_len > 0) self.cmd_len -= 1;
                return .none;
            },
            .char => |c| {
                if (self.cmd_len < max_cmd_len) {
                    self.cmd_buf[self.cmd_len] = c;
                    self.cmd_len += 1;
                }
                return .none;
            },
            .ctrl_c => return .none,
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

test "command mode collects text until enter" {
    var input: ModalInput = .{};
    try std.testing.expectEqual(Action{ .mode_changed = .command }, press(&input, ":"));
    _ = press(&input, "wqx");
    _ = input.handle(.backspace);
    const action = input.handle(.enter);
    try std.testing.expectEqualStrings("wq", action.command_submit);
    try std.testing.expectEqual(Mode.normal, input.mode);
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

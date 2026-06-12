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
    octave_down,
    octave_up,
    /// Insert-mode key mapped through the piano layout.
    note: struct { pitch: u7 },
    /// Slice is valid until command mode is entered again.
    command_submit: []const u8,

    pub const Move = struct { dx: i32 = 0, dy: i32 = 0 };
};

/// Tracker-style piano layout: the z-row is the lower octave's white
/// and black keys, the q-row sits one octave above. With octave 4,
/// 'z' is middle C (MIDI 60).
pub fn noteForChar(c: u8, octave: u4) ?u7 {
    const semi: u8 = switch (c) {
        'z' => 0,
        's' => 1,
        'x' => 2,
        'd' => 3,
        'c' => 4,
        'v' => 5,
        'g' => 6,
        'b' => 7,
        'h' => 8,
        'n' => 9,
        'j' => 10,
        'm' => 11,
        ',' => 12,
        'q' => 12,
        '2' => 13,
        'w' => 14,
        '3' => 15,
        'e' => 16,
        'r' => 17,
        '5' => 18,
        't' => 19,
        '6' => 20,
        'y' => 21,
        '7' => 22,
        'u' => 23,
        'i' => 24,
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
    fn takeCount(self: *ModalInput) i32 {
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
            'v' => return self.setMode(if (self.mode == .visual) .normal else .visual),
            ':' => {
                self.cmd_len = 0;
                return self.setMode(.command);
            },
            ' ' => return .toggle_play,
            'm' => return .toggle_mute,
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
            '-' => {
                if (self.octave > 0) self.octave -= 1;
                return .octave_down;
            },
            '=' => {
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
    try std.testing.expectEqual(Action{ .note = .{ .pitch = 60 } }, press(&input, "z")); // middle C
    try std.testing.expectEqual(Action{ .note = .{ .pitch = 64 } }, press(&input, "c")); // E
    try std.testing.expectEqual(Action{ .note = .{ .pitch = 72 } }, press(&input, "q")); // C5

    _ = press(&input, "-"); // octave down
    try std.testing.expectEqual(Action{ .note = .{ .pitch = 48 } }, press(&input, "z"));

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
    _ = press(&input, "42");
    _ = input.handle(.escape);
    try std.testing.expectEqual(Action{ .move = .{ .dy = 1 } }, press(&input, "j"));
}

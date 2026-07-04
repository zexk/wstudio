//! Raw terminal handling: termios raw mode, alternate screen, input
//! byte decoding, and whole-frame writes. Zero dependencies — just
//! std.posix and ANSI escape sequences.

const std = @import("std");
const Key = @import("wstudio").input.Key;

const esc = "\x1b";
const enter_alt_screen = esc ++ "[?1049h";
const leave_alt_screen = esc ++ "[?1049l";
const hide_cursor = esc ++ "[?25l";
const show_cursor = esc ++ "[?25h";

pub const Size = struct { cols: u16, rows: u16 };

pub const Terminal = struct {
    io: std.Io,
    stdin_fd: std.posix.fd_t,
    stdout_fd: std.posix.fd_t,
    original: std.posix.termios,

    pub fn init(io: std.Io) !Terminal {
        const stdin_fd: std.posix.fd_t = 0;
        const stdout_fd: std.posix.fd_t = 1;
        const original = std.posix.tcgetattr(stdin_fd) catch return error.NotATerminal;

        var raw = original;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false; // ctrl-c arrives as a byte; frontend quits cleanly
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.oflag.OPOST = false; // frames use explicit \r\n
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(stdin_fd, .FLUSH, raw);

        const self: Terminal = .{
            .io = io,
            .stdin_fd = stdin_fd,
            .stdout_fd = stdout_fd,
            .original = original,
        };
        self.write(enter_alt_screen ++ hide_cursor);
        return self;
    }

    pub fn deinit(self: *Terminal) void {
        self.write(show_cursor ++ leave_alt_screen);
        std.posix.tcsetattr(self.stdin_fd, .FLUSH, self.original) catch {};
    }

    pub fn write(self: *const Terminal, bytes: []const u8) void {
        std.Io.File.stdout().writeStreamingAll(self.io, bytes) catch {};
    }

    pub fn size(self: *const Terminal) Size {
        var ws: std.posix.winsize = undefined;
        const rc = std.posix.system.ioctl(
            self.stdout_fd,
            std.posix.T.IOCGWINSZ,
            @intFromPtr(&ws),
        );
        if (std.posix.errno(rc) != .SUCCESS or ws.col == 0 or ws.row == 0) {
            return .{ .cols = 80, .rows = 24 };
        }
        return .{ .cols = ws.col, .rows = ws.row };
    }

    /// Waits up to `timeout_ms` for input, then reads whatever is
    /// available. Returns the filled prefix of `buf` (empty on timeout).
    pub fn readInput(self: *const Terminal, buf: []u8, timeout_ms: i32) ![]const u8 {
        var fds = [_]std.posix.pollfd{.{
            .fd = self.stdin_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&fds, timeout_ms);
        if (ready == 0) return buf[0..0];
        const n = try std.posix.read(self.stdin_fd, buf);
        return buf[0..n];
    }
};

/// Decodes a batch of raw input bytes into keys. A lone 0x1b in the batch is
/// the escape key; 0x1b followed by '[' is a CSI sequence — arrows, Home
/// (xterm/alacritty's plain `ESC [ H`, not the `1~` form) and End (`ESC [ F`)
/// decode to their own Key variants (not hjkl chars, so the modal layer can
/// tell a real arrow press from someone typing those letters — see
/// App.handleKey), other CSI sequences are dropped. Returns the number of
/// keys written to `out`.
pub fn decode(bytes: []const u8, out: []Key) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < bytes.len and count < out.len) {
        const b = bytes[i];
        switch (b) {
            0x1b => {
                if (i + 1 < bytes.len and bytes[i + 1] == '[') {
                    i += 2;
                    // skip CSI parameters, keep the final byte
                    while (i < bytes.len and (bytes[i] < 0x40 or bytes[i] > 0x7e)) i += 1;
                    if (i < bytes.len) {
                        const final = bytes[i];
                        i += 1;
                        const mapped: ?Key = switch (final) {
                            'A' => .arrow_up,
                            'B' => .arrow_down,
                            'C' => .arrow_right,
                            'D' => .arrow_left,
                            'H' => .home,
                            'F' => .end,
                            else => null,
                        };
                        if (mapped) |k| {
                            out[count] = k;
                            count += 1;
                        }
                    }
                } else {
                    out[count] = .escape;
                    count += 1;
                    i += 1;
                }
            },
            '\r', '\n' => {
                out[count] = .enter;
                count += 1;
                i += 1;
            },
            0x7f, 0x08 => {
                out[count] = .backspace;
                count += 1;
                i += 1;
            },
            0x03 => {
                out[count] = .ctrl_c;
                count += 1;
                i += 1;
            },
            0x17 => {
                out[count] = .ctrl_w;
                count += 1;
                i += 1;
            },
            0x09 => {
                out[count] = .tab;
                count += 1;
                i += 1;
            },
            0x20...0x7e => {
                out[count] = .{ .char = b };
                count += 1;
                i += 1;
            },
            else => i += 1, // drop other control bytes
        }
    }
    return count;
}

test "decode printable, enter, backspace, ctrl-c, ctrl-w, tab" {
    var keys: [8]Key = undefined;
    const n = decode("ab\r\x7f\x03\x17\t", &keys);
    try std.testing.expectEqual(@as(usize, 7), n);
    try std.testing.expectEqual(Key{ .char = 'a' }, keys[0]);
    try std.testing.expectEqual(Key{ .char = 'b' }, keys[1]);
    try std.testing.expectEqual(Key.enter, keys[2]);
    try std.testing.expectEqual(Key.backspace, keys[3]);
    try std.testing.expectEqual(Key.ctrl_c, keys[4]);
    try std.testing.expectEqual(Key.ctrl_w, keys[5]);
    try std.testing.expectEqual(Key.tab, keys[6]);
}

test "lone escape vs CSI arrow sequences" {
    var keys: [8]Key = undefined;
    try std.testing.expectEqual(@as(usize, 1), decode("\x1b", &keys));
    try std.testing.expectEqual(Key.escape, keys[0]);

    // arrows decode to their own variants (App.handleKey aliases them to
    // hjkl outside command mode; see modal.zig's doc comment)
    const n = decode("\x1b[A\x1b[B\x1b[C\x1b[D", &keys);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(Key.arrow_up, keys[0]);
    try std.testing.expectEqual(Key.arrow_down, keys[1]);
    try std.testing.expectEqual(Key.arrow_right, keys[2]);
    try std.testing.expectEqual(Key.arrow_left, keys[3]);

    // unknown CSI (e.g. F1 variants) is dropped, not misread
    try std.testing.expectEqual(@as(usize, 0), decode("\x1b[15~", &keys));
}

test "decode Home/End CSI sequences" {
    var keys: [8]Key = undefined;
    const n = decode("\x1b[H\x1b[F", &keys);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(Key.home, keys[0]);
    try std.testing.expectEqual(Key.end, keys[1]);
}

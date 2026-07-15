//! Raw terminal handling (POSIX): termios raw mode, alternate screen, and
//! whole-frame writes. Zero dependencies - just std.posix and ANSI escape
//! sequences. Input byte decoding lives in input_decode.zig, shared with
//! terminal_windows.zig.

const std = @import("std");
const input_decode = @import("input_decode.zig");

pub const Size = input_decode.Size;
pub const decode = input_decode.decode;

const esc = "\x1b";
const enter_alt_screen = esc ++ "[?1049h";
const leave_alt_screen = esc ++ "[?1049l";
const hide_cursor = esc ++ "[?25l";
const show_cursor = esc ++ "[?25h";
/// DEC 2026 synchronized update: the terminal (and tmux in between) holds
/// repaints until the end marker, so a full-frame redraw can never be
/// sampled half-applied. Terminals without support ignore the private mode.
pub const begin_sync = esc ++ "[?2026h";
pub const end_sync = esc ++ "[?2026l";
// Button-event tracking (press/release + motion while a button is held) with
// SGR extended coordinates (unambiguous past column/row 223, and easy to
// parse back out - see `decode`'s SGR branch). Terminals conventionally let
// the user hold Shift to bypass this for native text selection.
const enable_mouse = esc ++ "[?1002h" ++ esc ++ "[?1006h";
const disable_mouse = esc ++ "[?1002l" ++ esc ++ "[?1006l";

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
        self.write(enter_alt_screen ++ hide_cursor ++ enable_mouse);
        return self;
    }

    pub fn deinit(self: *Terminal) void {
        self.write(disable_mouse ++ show_cursor ++ leave_alt_screen);
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

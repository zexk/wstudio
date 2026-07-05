//! Console handling (Windows): VT100 passthrough on stdin/stdout so the
//! rest of the TUI (ANSI frames, escape-coded input) is identical to the
//! POSIX build. Raw mode here means disabling line/echo/processed input
//! and asking the console to speak VT instead of translating it itself —
//! input byte decoding lives in input_decode.zig, shared with terminal.zig.

const std = @import("std");
const input_decode = @import("input_decode.zig");

const c = @cImport({
    @cInclude("windows.h");
});

pub const Size = input_decode.Size;
pub const decode = input_decode.decode;

const esc = "\x1b";
const enter_alt_screen = esc ++ "[?1049h";
const leave_alt_screen = esc ++ "[?1049l";
const hide_cursor = esc ++ "[?25l";
const show_cursor = esc ++ "[?25h";
const enable_mouse = esc ++ "[?1002h" ++ esc ++ "[?1006h";
const disable_mouse = esc ++ "[?1002l" ++ esc ++ "[?1006l";

pub const Terminal = struct {
    stdin: c.HANDLE,
    stdout: c.HANDLE,
    original_in_mode: c.DWORD,
    original_out_mode: c.DWORD,
    original_in_cp: c.UINT,
    original_out_cp: c.UINT,
    /// False if the `SetConsoleMode` call below didn't take (rare, but
    /// silent on failure otherwise) — QuickEdit stays on, so a click can
    /// still freeze the whole console (input *and* our own redraws) until
    /// the user presses Escape/Enter to release the selection. `run()`
    /// surfaces this as a status message once `App` exists.
    raw_mode_ok: bool,

    pub fn init(io: std.Io) !Terminal {
        _ = io;
        const stdin = c.GetStdHandle(c.STD_INPUT_HANDLE);
        const stdout = c.GetStdHandle(c.STD_OUTPUT_HANDLE);
        if (stdin == c.INVALID_HANDLE_VALUE or stdout == c.INVALID_HANDLE_VALUE)
            return error.NotATerminal;

        var original_in_mode: c.DWORD = 0;
        var original_out_mode: c.DWORD = 0;
        if (c.GetConsoleMode(stdin, &original_in_mode) == 0) return error.NotATerminal;
        if (c.GetConsoleMode(stdout, &original_out_mode) == 0) return error.NotATerminal;

        // The console's active code page decides how ReadFile/WriteFile bytes
        // get interpreted — without forcing it to UTF-8, non-ASCII bytes (icon
        // glyphs on output, non-ASCII keystrokes on input) get reinterpreted
        // through whatever OEM/ANSI code page the system defaults to, unlike
        // POSIX terminals which are UTF-8 by convention already.
        const original_in_cp = c.GetConsoleCP();
        const original_out_cp = c.GetConsoleOutputCP();
        _ = c.SetConsoleCP(c.CP_UTF8);
        _ = c.SetConsoleOutputCP(c.CP_UTF8);

        // Extended flags must be set for QuickEdit to actually turn off —
        // otherwise the console keeps intercepting clicks for text
        // selection instead of reporting them as VT mouse sequences.
        const raw_in_mode: c.DWORD = (original_in_mode | c.ENABLE_VIRTUAL_TERMINAL_INPUT |
            c.ENABLE_MOUSE_INPUT | c.ENABLE_EXTENDED_FLAGS) &
            ~@as(c.DWORD, c.ENABLE_ECHO_INPUT | c.ENABLE_LINE_INPUT |
                c.ENABLE_PROCESSED_INPUT | c.ENABLE_QUICK_EDIT_MODE);
        const raw_mode_ok = c.SetConsoleMode(stdin, raw_in_mode) != 0;

        const raw_out_mode: c.DWORD = original_out_mode | c.ENABLE_VIRTUAL_TERMINAL_PROCESSING |
            c.DISABLE_NEWLINE_AUTO_RETURN;
        _ = c.SetConsoleMode(stdout, raw_out_mode);

        const self: Terminal = .{
            .stdin = stdin,
            .stdout = stdout,
            .original_in_mode = original_in_mode,
            .original_out_mode = original_out_mode,
            .original_in_cp = original_in_cp,
            .original_out_cp = original_out_cp,
            .raw_mode_ok = raw_mode_ok,
        };
        self.write(enter_alt_screen ++ hide_cursor ++ enable_mouse);
        return self;
    }

    pub fn deinit(self: *Terminal) void {
        self.write(disable_mouse ++ show_cursor ++ leave_alt_screen);
        _ = c.SetConsoleMode(self.stdin, self.original_in_mode);
        _ = c.SetConsoleMode(self.stdout, self.original_out_mode);
        _ = c.SetConsoleCP(self.original_in_cp);
        _ = c.SetConsoleOutputCP(self.original_out_cp);
    }

    pub fn write(self: *const Terminal, bytes: []const u8) void {
        var written: c.DWORD = 0;
        _ = c.WriteFile(self.stdout, bytes.ptr, @intCast(bytes.len), &written, null);
    }

    pub fn size(self: *const Terminal) Size {
        var info: c.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (c.GetConsoleScreenBufferInfo(self.stdout, &info) == 0) return .{ .cols = 80, .rows = 24 };
        const cols = info.srWindow.Right - info.srWindow.Left + 1;
        const rows = info.srWindow.Bottom - info.srWindow.Top + 1;
        if (cols <= 0 or rows <= 0) return .{ .cols = 80, .rows = 24 };
        return .{ .cols = @intCast(cols), .rows = @intCast(rows) };
    }

    /// Waits up to `timeout_ms` for input, then reads whatever is
    /// available. Returns the filled prefix of `buf` (empty on timeout).
    pub fn readInput(self: *const Terminal, buf: []u8, timeout_ms: i32) ![]const u8 {
        const wait_ms: c.DWORD = if (timeout_ms < 0) c.INFINITE else @intCast(timeout_ms);
        if (c.WaitForSingleObject(self.stdin, wait_ms) != c.WAIT_OBJECT_0) return buf[0..0];
        var read: c.DWORD = 0;
        if (c.ReadFile(self.stdin, buf.ptr, @intCast(buf.len), &read, null) == 0) return buf[0..0];
        return buf[0..read];
    }
};

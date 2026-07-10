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
/// DEC 2026 synchronized update — see terminal.zig; Windows Terminal
/// supports it, legacy conhost ignores the private mode.
pub const begin_sync = esc ++ "[?2026h";
pub const end_sync = esc ++ "[?2026l";
const enable_mouse = esc ++ "[?1002h" ++ esc ++ "[?1006h";
const disable_mouse = esc ++ "[?1002l" ++ esc ++ "[?1006l";

pub const Terminal = struct {
    io: std.Io,
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
        // Deliberately NOT setting ENABLE_WINDOW_INPUT: it would queue a
        // WINDOW_BUFFER_SIZE_EVENT record on resize, which bumps
        // `GetNumberOfConsoleInputEvents` above zero without ever
        // producing readable bytes — `readInput` would then call the
        // blocking `ReadFile` and hang until a real keystroke, right back
        // to the freeze this file's `readInput` poll loop exists to avoid.
        // Resize is already handled every frame since `term.size()` is
        // re-queried unconditionally on each draw.
        const raw_in_mode: c.DWORD = (original_in_mode | c.ENABLE_VIRTUAL_TERMINAL_INPUT |
            c.ENABLE_MOUSE_INPUT | c.ENABLE_EXTENDED_FLAGS) &
            ~@as(c.DWORD, c.ENABLE_ECHO_INPUT | c.ENABLE_LINE_INPUT |
                c.ENABLE_PROCESSED_INPUT | c.ENABLE_QUICK_EDIT_MODE);
        const raw_mode_ok = c.SetConsoleMode(stdin, raw_in_mode) != 0;

        const raw_out_mode: c.DWORD = original_out_mode | c.ENABLE_VIRTUAL_TERMINAL_PROCESSING |
            c.DISABLE_NEWLINE_AUTO_RETURN;
        _ = c.SetConsoleMode(stdout, raw_out_mode);

        const self: Terminal = .{
            .io = io,
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

    /// True when the front of the input queue holds at least one record
    /// `ReadFile` can turn into bytes. Conhost translates input to VT byte
    /// sequences as events *enter* the queue (synthesized KEY_EVENTs whose
    /// uChar carries the bytes), so records that arrive untranslated — focus
    /// events (queued on alt-tab regardless of console mode), key releases,
    /// bare modifier presses, media/F-keys, mouse motion with no button held
    /// — will never satisfy a read. Left in place they keep the queue count
    /// nonzero while the blocking `ReadFile` starves: tap Shift or alt-tab
    /// during playback and every redraw freezes until the next real
    /// keystroke. So they're consumed and discarded here instead. Raw
    /// VK-coded key-downs a console could still translate at read time
    /// (arrows, Home/End, paging) are kept as readable, just in case some
    /// host defers translation to the read.
    fn queueHasReadableInput(stdin: c.HANDLE) bool {
        var records: [32]c.INPUT_RECORD = undefined;
        var count: c.DWORD = 0;
        if (c.PeekConsoleInputW(stdin, &records, records.len, &count) == 0 or count == 0)
            return false;
        for (records[0..count]) |rec| {
            if (rec.EventType != c.KEY_EVENT) continue;
            const key = rec.Event.KeyEvent;
            if (key.bKeyDown == 0) continue;
            if (key.uChar.UnicodeChar != 0) return true;
            switch (key.wVirtualKeyCode) {
                c.VK_UP, c.VK_DOWN, c.VK_LEFT, c.VK_RIGHT,
                c.VK_HOME, c.VK_END, c.VK_PRIOR, c.VK_NEXT,
                c.VK_INSERT, c.VK_DELETE => return true,
                else => {},
            }
        }
        var discarded: c.DWORD = 0;
        _ = c.ReadConsoleInputW(stdin, &records, count, &discarded);
        return false;
    }

    /// Waits up to `timeout_ms` for input, then reads whatever is
    /// available. Returns the filled prefix of `buf` (empty on timeout).
    ///
    /// Polls the input queue in short slices instead of a single
    /// `WaitForSingleObject(stdin, timeout_ms)` — with
    /// ENABLE_VIRTUAL_TERMINAL_INPUT on, the console handle's wait state
    /// tracks its internal event queue, not the VT-translated byte stream
    /// `ReadFile` hands back, and in practice that left the handle
    /// unsignaled (wait never timing out) for the whole span between real
    /// keystrokes — freezing every audio-driven redraw (playhead, meters,
    /// auto-scroll) until the next keypress instead of ticking every frame.
    /// The poll itself must not trust the raw event *count* either — see
    /// `queueHasReadableInput` for why byte-free records are filtered out
    /// before committing to the blocking `ReadFile`.
    pub fn readInput(self: *const Terminal, buf: []u8, timeout_ms: i32) ![]const u8 {
        const slice_ms: i32 = 5;
        var remaining: i32 = timeout_ms;
        while (true) {
            if (queueHasReadableInput(self.stdin)) break;
            if (timeout_ms >= 0) {
                if (remaining <= 0) return buf[0..0];
                remaining -= slice_ms;
            }
            self.io.sleep(.fromMilliseconds(slice_ms), .awake) catch return buf[0..0];
        }
        var read: c.DWORD = 0;
        if (c.ReadFile(self.stdin, buf.ptr, @intCast(buf.len), &read, null) == 0) return buf[0..0];
        return buf[0..read];
    }
};

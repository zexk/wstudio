//! ANSI/VT input decoding shared by every terminal backend (POSIX raw
//! mode, Windows console VT mode, ...). Pure byte-stream parsing, no
//! platform I/O, so one implementation covers all of them.

const std = @import("std");
const modal_mod = @import("wstudio").input;
const Key = modal_mod.Key;

pub const Size = struct { cols: u16, rows: u16 };

/// Carries a terminal escape sequence across reads. PTYs may split even a
/// short arrow or mouse report at any byte boundary.
pub const StreamDecoder = struct {
    pending: [256]u8 = undefined,
    pending_len: usize = 0,

    pub fn feed(self: *StreamDecoder, bytes: []const u8, out: []Key) usize {
        const kept = @min(bytes.len, self.pending.len - self.pending_len);
        @memcpy(self.pending[self.pending_len..][0..kept], bytes[0..kept]);
        self.pending_len += kept;

        var end: usize = 0;
        while (end < self.pending_len) {
            if (self.pending[end] != 0x1b) {
                end += 1;
                continue;
            }
            if (end + 1 == self.pending_len) break;
            if (self.pending[end + 1] != '[') {
                end += 1;
                continue;
            }
            var final = end + 2;
            while (final < self.pending_len and (self.pending[final] < 0x40 or self.pending[final] > 0x7e)) final += 1;
            if (final == self.pending_len) break;
            end = final + 1;
        }

        // An escape prefix is only distinguishable from a split sequence
        // after one poll returns no further bytes. On timeout, emit Escape
        // and decode the remaining bytes literally so a truncated CSI cannot
        // swallow the next real key indefinitely.
        if (bytes.len == 0 and self.pending_len > 0 and self.pending[0] == 0x1b and end == 0) {
            if (out.len == 0) return 0;
            out[0] = .escape;
            const tail_count = decode(self.pending[1..self.pending_len], out[1..]);
            self.pending_len = 0;
            return tail_count + 1;
        }

        const count = decode(self.pending[0..end], out);
        std.mem.copyForwards(u8, self.pending[0 .. self.pending_len - end], self.pending[end..self.pending_len]);
        self.pending_len -= end;
        return count;
    }
};

/// Parses the parameter block of an SGR mouse report (everything between the
/// leading `<` and the final `M`/`m`): `Cb;Cx;Cy`. `is_press` is true when the
/// sequence's final byte was `M` (press or motion), false for `m` (release -
/// see `Key.mouse`'s doc comment for the byte layout this decodes).
fn parseSgrMouse(params: []const u8, is_press: bool) ?Key {
    var it = std.mem.splitScalar(u8, params, ';');
    const cb = std.fmt.parseInt(u16, it.next() orelse return null, 10) catch return null;
    const cx = std.fmt.parseInt(u16, it.next() orelse return null, 10) catch return null;
    const cy = std.fmt.parseInt(u16, it.next() orelse return null, 10) catch return null;
    if (it.next() != null or cx == 0 or cy == 0) return null;

    const is_wheel = cb & 0x40 != 0;
    const is_motion = cb & 0x20 != 0;
    const btn_bits = cb & 0x3;
    const ctrl = cb & 0x10 != 0;
    const shift = cb & 0x4 != 0;

    // SGR reserves wheel button codes 2 and 3 for horizontal scrolling,
    // which the TUI has no key representation for.
    if (is_wheel and btn_bits >= 2) return null;

    const button: modal_mod.MouseButton = if (is_wheel) .none else switch (btn_bits) {
        0 => .left,
        1 => .middle,
        2 => .right,
        else => .none,
    };
    const kind: modal_mod.MouseKind = if (is_wheel)
        (if (btn_bits == 0) .scroll_up else .scroll_down)
    else if (is_motion)
        .drag
    else if (is_press)
        .press
    else
        .release;

    return .{ .mouse = .{
        .x = cx -| 1,
        .y = cy -| 1,
        .button = button,
        .kind = kind,
        .ctrl = ctrl,
        .shift = shift,
    } };
}

/// Leading decimal number of a CSI parameter block, ignoring anything from
/// the first `;` on (modifier suffixes like `1;5~` for ctrl+Home). Used for
/// the numbered Home/End forms (`ESC [ 1 ~` / `ESC [ 4 ~`, tmux's default),
/// distinct from the plain-letter forms (`ESC [ H` / `ESC [ F`).
fn leadingCsiNum(params: []const u8) ?u16 {
    const end = std.mem.indexOfScalar(u8, params, ';') orelse params.len;
    return std.fmt.parseInt(u16, params[0..end], 10) catch null;
}

/// Decodes a batch of raw input bytes into keys. A lone 0x1b in the batch is
/// the escape key; 0x1b followed by '[' is a CSI sequence - arrows, Home
/// (xterm/alacritty's plain `ESC [ H` or the numbered `ESC [ 1 ~` / `7 ~`
/// forms), End (`ESC [ F` or `ESC [ 4 ~` / `8 ~`), and SGR mouse reports
/// (`ESC [ < Cb ; Cx ; Cy M`/`m`) decode to their own Key variants (arrows/
/// Home/End not aliased to hjkl chars, so the modal layer can tell a real
/// arrow press from someone typing those letters - see App.handleKey),
/// other CSI sequences are dropped. Returns the number of keys written to
/// `out`.
pub fn decode(bytes: []const u8, out: []Key) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < bytes.len and count < out.len) {
        const b = bytes[i];
        switch (b) {
            0x1b => {
                if (i + 1 < bytes.len and bytes[i + 1] == '[') {
                    const param_start = i + 2;
                    i = param_start;
                    // skip CSI parameters, keep the final byte
                    while (i < bytes.len and (bytes[i] < 0x40 or bytes[i] > 0x7e)) i += 1;
                    if (i < bytes.len) {
                        const final = bytes[i];
                        const params = bytes[param_start..i];
                        i += 1;
                        const mapped: ?Key = if (params.len > 0 and params[0] == '<' and (final == 'M' or final == 'm'))
                            parseSgrMouse(params[1..], final == 'M')
                        else if (final == '~')
                            switch (leadingCsiNum(params) orelse 0) {
                                1, 7 => .home,
                                4, 8 => .end,
                                else => null,
                            }
                        else switch (final) {
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
            0x12 => {
                out[count] = .ctrl_r;
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

test "decode printable, enter, backspace, ctrl-c, ctrl-w, ctrl-r, tab" {
    var keys: [8]Key = undefined;
    const n = decode("ab\r\x7f\x03\x17\x12\t", &keys);
    try std.testing.expectEqual(@as(usize, 8), n);
    try std.testing.expectEqual(Key{ .char = 'a' }, keys[0]);
    try std.testing.expectEqual(Key{ .char = 'b' }, keys[1]);
    try std.testing.expectEqual(Key.enter, keys[2]);
    try std.testing.expectEqual(Key.backspace, keys[3]);
    try std.testing.expectEqual(Key.ctrl_c, keys[4]);
    try std.testing.expectEqual(Key.ctrl_w, keys[5]);
    try std.testing.expectEqual(Key.ctrl_r, keys[6]);
    try std.testing.expectEqual(Key.tab, keys[7]);
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

test "stream decoder preserves escape sequences split across reads" {
    var decoder: StreamDecoder = .{};
    var keys: [4]Key = undefined;

    try std.testing.expectEqual(@as(usize, 0), decoder.feed("\x1b[", &keys));
    try std.testing.expectEqual(@as(usize, 1), decoder.feed("A", &keys));
    try std.testing.expectEqual(Key.arrow_up, keys[0]);

    try std.testing.expectEqual(@as(usize, 0), decoder.feed("\x1b[<0;12;", &keys));
    try std.testing.expectEqual(@as(usize, 1), decoder.feed("7M", &keys));
    try std.testing.expectEqual(Key.mouse, std.meta.activeTag(keys[0]));
    try std.testing.expectEqual(@as(u16, 11), keys[0].mouse.x);
    try std.testing.expectEqual(@as(u16, 6), keys[0].mouse.y);
}

test "stream decoder defers a lone escape for one poll" {
    var decoder: StreamDecoder = .{};
    var keys: [1]Key = undefined;
    try std.testing.expectEqual(@as(usize, 0), decoder.feed("\x1b", &keys));
    try std.testing.expectEqual(@as(usize, 1), decoder.feed("", &keys));
    try std.testing.expectEqual(Key.escape, keys[0]);
}

test "stream decoder times out a truncated CSI without swallowing later keys" {
    var decoder: StreamDecoder = .{};
    var keys: [4]Key = undefined;
    try std.testing.expectEqual(@as(usize, 0), decoder.feed("\x1b[", &keys));
    try std.testing.expectEqual(@as(usize, 2), decoder.feed("", &keys));
    try std.testing.expectEqual(Key.escape, keys[0]);
    try std.testing.expectEqual(Key{ .char = '[' }, keys[1]);

    try std.testing.expectEqual(@as(usize, 1), decoder.feed("a", &keys));
    try std.testing.expectEqual(Key{ .char = 'a' }, keys[0]);
}

test "decode Home/End CSI sequences" {
    var keys: [8]Key = undefined;
    const n = decode("\x1b[H\x1b[F", &keys);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(Key.home, keys[0]);
    try std.testing.expectEqual(Key.end, keys[1]);
}

test "decode numbered Home/End CSI sequences (tmux/rxvt)" {
    var keys: [8]Key = undefined;
    const n = decode("\x1b[1~\x1b[4~\x1b[7~\x1b[8~", &keys);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(Key.home, keys[0]);
    try std.testing.expectEqual(Key.end, keys[1]);
    try std.testing.expectEqual(Key.home, keys[2]);
    try std.testing.expectEqual(Key.end, keys[3]);
}

test "decode SGR mouse press/release/drag" {
    var keys: [8]Key = undefined;
    // left press at col 5, row 3 (1-based on the wire -> 0-based decoded)
    var n = decode("\x1b[<0;5;3M", &keys);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(modal_mod.MouseEvent{
        // zig fmt: off
        .x = 4, .y = 2, .button = .left, .kind = .press,
        // zig fmt: on
    }, keys[0].mouse);

    // left release, same cell
    n = decode("\x1b[<0;5;3m", &keys);
    try std.testing.expectEqual(modal_mod.MouseKind.release, keys[0].mouse.kind);

    // motion with the left button held (bit 0x20) - a drag
    n = decode("\x1b[<32;6;3M", &keys);
    try std.testing.expectEqual(modal_mod.MouseKind.drag, keys[0].mouse.kind);
    try std.testing.expectEqual(@as(u16, 5), keys[0].mouse.x);
}

test "decode SGR mouse wheel and modifiers" {
    var keys: [8]Key = undefined;
    // wheel up (Cb bit 0x40 set, button bits 0) and wheel down (bits 1)
    var n = decode("\x1b[<64;1;1M", &keys);
    try std.testing.expectEqual(modal_mod.MouseKind.scroll_up, keys[0].mouse.kind);
    n = decode("\x1b[<65;1;1M", &keys);
    try std.testing.expectEqual(modal_mod.MouseKind.scroll_down, keys[0].mouse.kind);

    // ctrl+left press (Cb bit 0x10) and shift+left press (Cb bit 0x4)
    n = decode("\x1b[<16;1;1M", &keys);
    try std.testing.expect(keys[0].mouse.ctrl);
    n = decode("\x1b[<4;1;1M", &keys);
    try std.testing.expect(keys[0].mouse.shift);
}

test "decode rejects malformed and unsupported SGR mouse reports" {
    var keys: [4]Key = undefined;
    try std.testing.expectEqual(@as(usize, 0), decode("\x1b[<0;0;1M", &keys));
    try std.testing.expectEqual(@as(usize, 0), decode("\x1b[<0;1;0M", &keys));
    try std.testing.expectEqual(@as(usize, 0), decode("\x1b[<0;1;1;9M", &keys));
    try std.testing.expectEqual(@as(usize, 0), decode("\x1b[<66;1;1M", &keys));
    try std.testing.expectEqual(@as(usize, 0), decode("\x1b[<67;1;1M", &keys));
}

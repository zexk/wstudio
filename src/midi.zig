//! MIDI protocol types, raw-byte parser, and note utilities.
//!
//! Pure protocol layer - no DSP dependency. CC→synth routing lives in
//! PolySynth.applyCC / PolySynth.applyPitchBend (dsp/synth.zig).

const std = @import("std");

// ============================================================
// Message types
// ============================================================

pub const Channel = u4;

pub const Msg = union(enum) {
    // zig fmt: off
    note_on:          NoteMsg,
    note_off:         NoteMsg,
    poly_aftertouch:  NoteMsg,
    control_change:   CcMsg,
    program_change:   PcMsg,
    channel_pressure: CpMsg,
    /// Signed 14-bit value: -8192 (full down) .. +8191 (full up); 0 = centre.
    pitch_bend:       BendMsg,
    clock, start, @"continue", stop, active_sensing, reset,

    pub const NoteMsg = struct { ch: Channel, note: u7, velocity: u7 };
    pub const CcMsg   = struct { ch: Channel, cc: u7, value: u7 };
    pub const PcMsg   = struct { ch: Channel, program: u7 };
    pub const CpMsg   = struct { ch: Channel, pressure: u7 };
    pub const BendMsg = struct { ch: Channel, bend: i16 };
};

/// Channel Voice messages decoded from Universal MIDI Packets. Values keep
/// their native MIDI 2.0 resolution; transport code decides whether its
/// destination can consume that resolution or needs MIDI 1.0 scaling.
pub const UmpMsg = union(enum) {
    midi1: Msg,
    note_on: NoteMsg,
    note_off: NoteMsg,
    poly_aftertouch: NoteDataMsg,
    per_note_rcc: PerNoteControllerMsg,
    per_note_acc: PerNoteControllerMsg,
    rpn: ControllerMsg,
    nrpn: ControllerMsg,
    relative_rpn: ControllerMsg,
    relative_nrpn: ControllerMsg,
    per_note_pitch_bend: NoteDataMsg,
    control_change: ControlChangeMsg,
    program_change: ProgramMsg,
    channel_pressure: ChannelDataMsg,
    pitch_bend: ChannelDataMsg,
    per_note_management: PerNoteManagementMsg,

    pub const Address = struct { group: u4, ch: Channel };
    pub const NoteMsg = struct { address: Address, note: u7, velocity: u16, attribute_type: u8, attribute_data: u16 };
    pub const NoteDataMsg = struct { address: Address, note: u7, data: u32 };
    pub const PerNoteControllerMsg = struct { address: Address, note: u7, index: u8, data: u32 };
    pub const ControllerMsg = struct { address: Address, bank: u7, index: u7, data: u32 };
    pub const ControlChangeMsg = struct { address: Address, index: u7, data: u32 };
    pub const ProgramMsg = struct { address: Address, program: u7, bank: ?struct { msb: u7, lsb: u7 } };
    pub const ChannelDataMsg = struct { address: Address, data: u32 };
    pub const PerNoteManagementMsg = struct { address: Address, note: u7, reset_controllers: bool, detach_controllers: bool };
};

/// Parse one complete UMP from host-order 32-bit words. Unknown but valid
/// packet types are consumed and ignored, letting callers continue at the
/// next packet without guessing boundaries.
pub const UmpParser = struct {
    pub const Result = struct { msg: ?UmpMsg, consumed: u3 };

    pub fn feed(words: []const u32) ?Result {
        if (words.len == 0) return null;
        const message_type: u4 = @truncate(words[0] >> 28);
        const count = wordCount(message_type);
        if (words.len < count) return null;

        return .{ .msg = switch (message_type) {
            0x1 => parseSystem(words[0]),
            0x2 => parseMidi1(words[0]),
            0x4 => parseMidi2(words[0], words[1]),
            else => null,
        }, .consumed = count };
    }

    pub fn wordCount(message_type: u4) u3 {
        return switch (message_type) {
            0x0, 0x1, 0x2, 0x6, 0x7 => 1,
            0x3, 0x4, 0x8, 0x9, 0xA => 2,
            0xB, 0xC => 3,
            0x5, 0xD, 0xE, 0xF => 4,
        };
    }

    fn parseSystem(word: u32) ?UmpMsg {
        const status: u8 = @truncate(word >> 16);
        const msg = realtimeMsg(status) orelse return null;
        return .{ .midi1 = msg };
    }

    fn parseMidi1(word: u32) ?UmpMsg {
        const status: u8 = @truncate(word >> 16);
        const d1: u7 = @truncate(word >> 8);
        const d2: u7 = @truncate(word);
        const ch: Channel = @truncate(status);
        if (word & 0x00008080 != 0) return null;
        const msg: Msg = switch (status >> 4) {
            0x8 => .{ .note_off = .{ .ch = ch, .note = d1, .velocity = d2 } },
            0x9 => if (d2 == 0)
                .{ .note_off = .{ .ch = ch, .note = d1, .velocity = 0 } }
            else
                .{ .note_on = .{ .ch = ch, .note = d1, .velocity = d2 } },
            0xA => .{ .poly_aftertouch = .{ .ch = ch, .note = d1, .velocity = d2 } },
            0xB => .{ .control_change = .{ .ch = ch, .cc = d1, .value = d2 } },
            0xC => .{ .program_change = .{ .ch = ch, .program = d1 } },
            0xD => .{ .channel_pressure = .{ .ch = ch, .pressure = d1 } },
            0xE => blk: {
                const raw: u14 = (@as(u14, d2) << 7) | d1;
                break :blk .{ .pitch_bend = .{ .ch = ch, .bend = @as(i16, @intCast(raw)) - 0x2000 } };
            },
            else => return null,
        };
        return .{ .midi1 = msg };
    }

    fn parseMidi2(first: u32, second: u32) ?UmpMsg {
        const address: UmpMsg.Address = .{ .group = @truncate(first >> 24), .ch = @truncate(first >> 16) };
        const status: u4 = @truncate(first >> 20);
        const byte2: u8 = @truncate(first >> 8);
        const byte3: u8 = @truncate(first);
        const note: u7 = @truncate(byte2);
        return switch (status) {
            0x0 => if (byte2 & 0x80 == 0) .{ .per_note_rcc = .{ .address = address, .note = note, .index = byte3, .data = second } } else null,
            0x1 => if (byte2 & 0x80 == 0) .{ .per_note_acc = .{ .address = address, .note = note, .index = byte3, .data = second } } else null,
            0x2 => if (byte2 & 0x80 == 0 and byte3 & 0x80 == 0) .{ .rpn = .{ .address = address, .bank = @truncate(byte2), .index = @truncate(byte3), .data = second } } else null,
            0x3 => if (byte2 & 0x80 == 0 and byte3 & 0x80 == 0) .{ .nrpn = .{ .address = address, .bank = @truncate(byte2), .index = @truncate(byte3), .data = second } } else null,
            0x4 => if (byte2 & 0x80 == 0 and byte3 & 0x80 == 0) .{ .relative_rpn = .{ .address = address, .bank = @truncate(byte2), .index = @truncate(byte3), .data = second } } else null,
            0x5 => if (byte2 & 0x80 == 0 and byte3 & 0x80 == 0) .{ .relative_nrpn = .{ .address = address, .bank = @truncate(byte2), .index = @truncate(byte3), .data = second } } else null,
            0x6 => if (byte2 & 0x80 == 0 and byte3 == 0) .{ .per_note_pitch_bend = .{ .address = address, .note = note, .data = second } } else null,
            0x8, 0x9 => blk: {
                if (byte2 & 0x80 != 0) break :blk null;
                const value: UmpMsg.NoteMsg = .{
                    .address = address,
                    .note = note,
                    .velocity = @truncate(second >> 16),
                    .attribute_type = byte3,
                    .attribute_data = @truncate(second),
                };
                break :blk if (status == 0x8) .{ .note_off = value } else .{ .note_on = value };
            },
            0xA => if (byte2 & 0x80 == 0 and byte3 == 0) .{ .poly_aftertouch = .{ .address = address, .note = note, .data = second } } else null,
            0xB => if (byte2 & 0x80 == 0 and byte3 == 0) .{ .control_change = .{ .address = address, .index = @truncate(byte2), .data = second } } else null,
            0xC => if (first & 0xFFFE == 0 and second & 0x00FF8080 == 0) .{ .program_change = .{
                .address = address,
                .program = @truncate(second >> 24),
                .bank = if (first & 1 != 0) .{ .msb = @truncate(second >> 8), .lsb = @truncate(second) } else null,
            } } else null,
            0xD => if (first & 0xFFFF == 0) .{ .channel_pressure = .{ .address = address, .data = second } } else null,
            0xE => if (first & 0xFFFF == 0) .{ .pitch_bend = .{ .address = address, .data = second } } else null,
            0xF => if (byte2 & 0x80 == 0 and byte3 & 0xFC == 0 and second == 0) .{ .per_note_management = .{
                .address = address,
                .note = note,
                .reset_controllers = byte3 & 1 != 0,
                .detach_controllers = byte3 & 2 != 0,
            } } else null,
            else => return null,
        };
    }
};

// ============================================================
// Note utilities
// ============================================================

const chromatic = [12][]const u8{ "C","C#","D","D#","E","F","F#","G","G#","A","A#","B" };
// zig fmt: on

/// Write note name into buf (e.g. "C4", "D#3"). Returns the written slice.
/// buf must be at least 4 bytes.
pub fn noteName(note: u7, buf: []u8) []const u8 {
    const octave: i8 = @as(i8, @intCast(note / 12)) - 1;
    return std.fmt.bufPrint(buf, "{s}{d}", .{ chromatic[note % 12], octave }) catch buf[0..0];
}

/// Standard 440 Hz equal-temperament: A4 = note 69.
pub fn noteToFreq(note: u7) f32 {
    return 440.0 * std.math.pow(f32, 2.0, (@as(f32, @floatFromInt(note)) - 69.0) / 12.0);
}

// ============================================================
// Parser
// ============================================================

/// Stateful byte-stream parser with running-status support.
/// All state fits in 3 bytes - copy-safe for snapshots.
pub const Parser = struct {
    running_status: u8 = 0,
    /// First data byte of a split 2-byte message carried across calls.
    d1: u7 = 0,
    have_d1: bool = false,

    pub const Result = struct { msg: Msg, consumed: usize };

    /// Parse one message from the front of `bytes`.
    /// Returns null when `bytes` is empty, is a partial 2-byte message,
    /// or contains an unrecognised status.
    pub fn feed(self: *Parser, bytes: []const u8) ?Result {
        // `base` walks forward when a status byte turns up where a data byte
        // was expected. A loop rather than re-entering `feed`, because one
        // CoreMIDI packet can be tens of kilobytes and a device emitting a
        // long run of status bytes would recurse once per byte.
        var base: usize = 0;
        restart: while (true) {
            var i: usize = base;
            var status = self.running_status;

            if (base < bytes.len and bytes[base] & 0x80 != 0) {
                status = bytes[base];
                i = base + 1;

                // System-realtime: single byte, no running-status update.
                if (realtimeMsg(status)) |msg| return .{ .msg = msg, .consumed = base + 1 };
                if (status < 0xF0) {
                    self.running_status = status;
                    self.have_d1 = false;
                } else {
                    self.running_status = 0;
                    self.have_d1 = false;
                    return null; // system-common not implemented
                }
            }

            if (status == 0) return null;

            const kind: u4 = @intCast(status >> 4);
            const ch: Channel = @intCast(status & 0x0F);

            // 1-data-byte messages: program change (0xC), channel pressure (0xD).
            if (kind == 0xC or kind == 0xD) {
                if (i >= bytes.len) return null;
                if (realtimeMsg(bytes[i])) |msg| return .{ .msg = msg, .consumed = i + 1 };
                if (bytes[i] & 0x80 != 0) {
                    self.have_d1 = false;
                    base = i;
                    continue :restart;
                }
                const d: u7 = @intCast(bytes[i] & 0x7F);
                i += 1;
                const msg: Msg = if (kind == 0xC)
                    // zig fmt: off
                    .{ .program_change   = .{ .ch = ch, .program  = d } }
                    // zig fmt: on
                else
                    .{ .channel_pressure = .{ .ch = ch, .pressure = d } };
                return .{ .msg = msg, .consumed = i };
            }

            // 2-data-byte messages.
            var d1: u7 = undefined;
            if (self.have_d1) {
                d1 = self.d1;
                self.have_d1 = false;
            } else {
                if (i >= bytes.len) return null;
                if (realtimeMsg(bytes[i])) |msg| return .{ .msg = msg, .consumed = i + 1 };
                if (bytes[i] & 0x80 != 0) {
                    self.have_d1 = false;
                    base = i;
                    continue :restart;
                }
                d1 = @intCast(bytes[i] & 0x7F);
                i += 1;
            }

            if (i >= bytes.len) {
                self.d1 = d1;
                self.have_d1 = true;
                return null;
            }

            if (realtimeMsg(bytes[i])) |msg| {
                self.d1 = d1;
                self.have_d1 = true;
                return .{ .msg = msg, .consumed = i + 1 };
            }
            if (bytes[i] & 0x80 != 0) {
                self.have_d1 = false;
                base = i;
                continue :restart;
            }

            const d2: u7 = @intCast(bytes[i] & 0x7F);
            i += 1;

            const msg: Msg = switch (kind) {
                0x8 => .{ .note_off = .{ .ch = ch, .note = d1, .velocity = d2 } },
                0x9 => if (d2 == 0)
                    // Velocity-0 note-on is a note-off per the MIDI spec.
                    .{ .note_off = .{ .ch = ch, .note = d1, .velocity = 0 } }
                else
                    // zig fmt: off
                    .{ .note_on  = .{ .ch = ch, .note = d1, .velocity = d2 } },
                0xA => .{ .poly_aftertouch = .{ .ch = ch, .note = d1, .velocity = d2 } },
                0xB => .{ .control_change  = .{ .ch = ch, .cc   = d1, .value    = d2 } },
                // zig fmt: on
                0xE => blk: {
                    const raw: u14 = (@as(u14, d2) << 7) | d1;
                    break :blk .{ .pitch_bend = .{ .ch = ch, .bend = @as(i16, @intCast(raw)) - 0x2000 } };
                },
                else => return null,
            };
            return .{ .msg = msg, .consumed = i };
        }
    }

    pub fn reset(self: *Parser) void {
        self.* = .{};
    }
};

fn realtimeMsg(status: u8) ?Msg {
    return switch (status) {
        // zig fmt: off
        0xF8 => .clock,
        0xFA => .start,
        0xFB => .@"continue",
        0xFC => .stop,
        0xFE => .active_sensing,
        0xFF => .reset,
        // zig fmt: on
        else => null,
    };
}

// ============================================================
// CC assignments
// ============================================================

/// Canonical CC number → PolySynth parameter assignments.
/// Standard GM numbers are respected where a convention exists.
pub const CC = enum(u7) {
    // zig fmt: off
    mod_wheel         = 1,   // → mod_wheel (0–1), the matrix `.wheel` source
    glide_time        = 5,   // → glide_s (0–4 s)
    gain              = 7,   // → output gain (0–1)
    osc_a_waveform    = 14,  // wavetable position
    osc_a_pulse_width = 15,  // retired
    osc_a_unison      = 16,  // → unison count (1–16)
    osc_a_unison_det  = 17,  // → unison_detune cents (0–100)
    osc_a_spread      = 18,  // → unison_spread (0–1)
    osc_b_on          = 20,  // >63 → on
    osc_b_waveform    = 21,  // wavetable position
    osc_b_semi        = 22,  // → osc_b_semi (−24..+24 semitones)
    osc_b_detune      = 23,  // → osc_b_detune_cents (−100..+100)
    osc_b_level       = 24,  // → osc_b_level (0–1)
    sub_level         = 25,  // → sub_level (0–1)
    noise_level       = 26,  // → noise_level (0–1)
    noise_color       = 27,  // → noise_color (0=dark … 1=white)
    lfo_rate          = 28,  // → lfo_rate_hz log (0.01–20 Hz)
    lfo_depth_cc      = 29,  // → mod_wheel (0–1), second alias of CC 1
    mod_amount        = 30,  // → OSC A warp amount (0–8)
    filter_res        = 71,  // GM timbre → filter_res (0–1)
    amp_release       = 72,  // GM release → release_s (0–4 s)
    amp_attack        = 73,  // GM attack → attack_s (0–4 s)
    filter_cutoff     = 74,  // GM brightness → filter_cutoff log (20–18 000 Hz)
    amp_decay         = 75,  // GM decay → decay_s (0–4 s)
    amp_sustain       = 76,  // → sustain level (0–1)
    fenv_amount       = 77,  // retired (fenv amount lives on mod-matrix rows now) - ignored
    fenv_attack       = 78,  // → fenv_attack_s (0–4 s)
    fenv_decay        = 79,  // → fenv_decay_s (0–4 s)
    fenv_sustain      = 80,  // → fenv_sustain (0–1)
    fenv_release      = 81,  // → fenv_release_s (0–4 s)
    all_sound_off     = 120, // GM mandatory - immediate silence
    reset_all_ctrls   = 121, // reset transient performance controllers
    local_control     = 122, // accepted; no separate local keyboard path
    all_notes_off     = 123, // GM mandatory - release all voices
    omni_mode_off     = 124, // mode change also releases all voices
    omni_mode_on      = 125,
    mono_mode_on      = 126,
    poly_mode_on      = 127,
    // zig fmt: on
    _,
};

// ============================================================
// Tests
// ============================================================

test "parser: note_on" {
    var p: Parser = .{};
    const r = p.feed(&.{ 0x90, 60, 100 }).?;
    try std.testing.expectEqual(@as(usize, 3), r.consumed);
    const m = r.msg.note_on;
    try std.testing.expectEqual(@as(Channel, 0), m.ch);
    try std.testing.expectEqual(@as(u7, 60), m.note);
    try std.testing.expectEqual(@as(u7, 100), m.velocity);
}

test "parser: velocity-0 note_on → note_off" {
    var p: Parser = .{};
    const r = p.feed(&.{ 0x90, 60, 0 }).?;
    try std.testing.expect(r.msg == .note_off);
    try std.testing.expectEqual(@as(u7, 60), r.msg.note_off.note);
}

test "parser: running status" {
    var p: Parser = .{};
    _ = p.feed(&.{ 0x90, 60, 80 }); // sets running status
    const r = p.feed(&.{ 62, 90 }).?; // no status byte - running status applies
    try std.testing.expect(r.msg == .note_on);
    try std.testing.expectEqual(@as(u7, 62), r.msg.note_on.note);
}

test "parser: realtime byte interleaved in channel message" {
    var p: Parser = .{};
    const realtime = p.feed(&.{ 0x90, 60, 0xF8, 100 }).?;
    try std.testing.expect(realtime.msg == .clock);
    try std.testing.expectEqual(@as(usize, 3), realtime.consumed);

    const note = p.feed(&.{100}).?;
    try std.testing.expect(note.msg == .note_on);
    try std.testing.expectEqual(@as(u7, 60), note.msg.note_on.note);
    try std.testing.expectEqual(@as(u7, 100), note.msg.note_on.velocity);
}

test "parser: realtime byte before first channel data byte" {
    var p: Parser = .{};
    const realtime = p.feed(&.{ 0x90, 0xFA }).?;
    try std.testing.expect(realtime.msg == .start);
    try std.testing.expectEqual(@as(usize, 2), realtime.consumed);

    const note = p.feed(&.{ 60, 100 }).?;
    try std.testing.expect(note.msg == .note_on);
    try std.testing.expectEqual(@as(u7, 60), note.msg.note_on.note);
}

test "parser: realtime byte interleaved in one-data-byte message" {
    var p: Parser = .{};
    const realtime = p.feed(&.{ 0xC0, 0xFC, 12 }).?;
    try std.testing.expect(realtime.msg == .stop);
    try std.testing.expectEqual(@as(usize, 2), realtime.consumed);

    const change = p.feed(&.{12}).?;
    try std.testing.expect(change.msg == .program_change);
    try std.testing.expectEqual(@as(u7, 12), change.msg.program_change.program);
}

test "parser: pitch bend centre" {
    var p: Parser = .{};
    // 0xE0 0x00 0x40 → raw = 0x2000 = 8192 → bend = 0
    const r = p.feed(&.{ 0xE0, 0x00, 0x40 }).?;
    try std.testing.expectEqual(@as(i16, 0), r.msg.pitch_bend.bend);
}

test "parser: split message across two calls" {
    var p: Parser = .{};
    try std.testing.expect(p.feed(&.{ 0x90, 60 }) == null);
    // zig fmt: off
    const r = p.feed(&.{ 80 }).?;
    // zig fmt: on
    try std.testing.expect(r.msg == .note_on);
    try std.testing.expectEqual(@as(u7, 60), r.msg.note_on.note);
}

test "parser: system-common status cancels running status" {
    var p: Parser = .{};
    _ = p.feed(&.{ 0x90, 60, 80 });
    try std.testing.expect(p.feed(&.{0xF1}) == null);
    try std.testing.expect(p.feed(&.{ 62, 90 }) == null);
}

test "parser: system-common status cancels partial channel message" {
    var p: Parser = .{};
    try std.testing.expect(p.feed(&.{ 0x90, 60 }) == null);
    try std.testing.expect(p.have_d1);
    try std.testing.expect(p.feed(&.{0xF2}) == null);
    try std.testing.expect(!p.have_d1);
    try std.testing.expect(p.feed(&.{80}) == null);
}

test "parser: new status replaces a channel message missing its second data byte" {
    var p: Parser = .{};
    const result = p.feed(&.{ 0x90, 60, 0x80, 61, 70 }).?;
    try std.testing.expect(result.msg == .note_off);
    try std.testing.expectEqual(@as(u7, 61), result.msg.note_off.note);
    try std.testing.expectEqual(@as(u7, 70), result.msg.note_off.velocity);
    try std.testing.expectEqual(@as(usize, 5), result.consumed);
}

test "parser: new status replaces a channel message missing its first data byte" {
    var p: Parser = .{};
    const result = p.feed(&.{ 0x90, 0xB2, 7, 100 }).?;
    try std.testing.expect(result.msg == .control_change);
    try std.testing.expectEqual(@as(Channel, 2), result.msg.control_change.ch);
    try std.testing.expectEqual(@as(u7, 7), result.msg.control_change.cc);
    try std.testing.expectEqual(@as(u7, 100), result.msg.control_change.value);
    try std.testing.expectEqual(@as(usize, 4), result.consumed);
}

test "parser: a long run of abandoned statuses does not recurse per byte" {
    // A max-size CoreMIDI packet (its length field is a UInt16) of status
    // bytes, each abandoning the last.
    // This used to re-enter feed() once per byte and overflow the stack.
    var bytes: [65535]u8 = @splat(0x90);
    bytes[bytes.len - 3] = 0xB2;
    bytes[bytes.len - 2] = 7;
    bytes[bytes.len - 1] = 100;

    var p: Parser = .{};
    const result = p.feed(&bytes).?;
    try std.testing.expect(result.msg == .control_change);
    try std.testing.expectEqual(@as(u7, 7), result.msg.control_change.cc);
    try std.testing.expectEqual(bytes.len, result.consumed);
}

test "noteName: spot checks" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("C4", noteName(60, &buf));
    try std.testing.expectEqualStrings("A4", noteName(69, &buf));
    try std.testing.expectEqualStrings("C-1", noteName(0, &buf));
}

test "UMP parser: packet sizes and truncation" {
    const expected = [_]u3{ 1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4 };
    for (expected, 0..) |count, message_type| {
        try std.testing.expectEqual(count, UmpParser.wordCount(@intCast(message_type)));
        const words = [_]u32{ @as(u32, @intCast(message_type)) << 28, 0, 0, 0 };
        try std.testing.expect(UmpParser.feed(words[0 .. count - 1]) == null);
        try std.testing.expectEqual(count, UmpParser.feed(words[0..count]).?.consumed);
    }
}

test "UMP parser: MIDI 1.0 Channel Voice" {
    const result = UmpParser.feed(&.{0x23903C64}).?;
    try std.testing.expectEqual(@as(u3, 1), result.consumed);
    const note = result.msg.?.midi1.note_on;
    try std.testing.expectEqual(@as(Channel, 0), note.ch);
    try std.testing.expectEqual(@as(u7, 60), note.note);
    try std.testing.expectEqual(@as(u7, 100), note.velocity);
}

test "UMP parser: MIDI 2.0 note and high-resolution velocity" {
    const result = UmpParser.feed(&.{ 0x45913C03, 0xABCD1234 }).?;
    try std.testing.expectEqual(@as(u3, 2), result.consumed);
    const note = result.msg.?.note_on;
    try std.testing.expectEqual(@as(u4, 5), note.address.group);
    try std.testing.expectEqual(@as(Channel, 1), note.address.ch);
    try std.testing.expectEqual(@as(u7, 60), note.note);
    try std.testing.expectEqual(@as(u16, 0xABCD), note.velocity);
    try std.testing.expectEqual(@as(u8, 3), note.attribute_type);
    try std.testing.expectEqual(@as(u16, 0x1234), note.attribute_data);
}

test "UMP parser: MIDI 2.0 controllers keep 32-bit data" {
    const cc = UmpParser.feed(&.{ 0x42B74A00, 0xFEDCBA98 }).?.msg.?.control_change;
    try std.testing.expectEqual(@as(u4, 2), cc.address.group);
    try std.testing.expectEqual(@as(Channel, 7), cc.address.ch);
    try std.testing.expectEqual(@as(u7, 74), cc.index);
    try std.testing.expectEqual(@as(u32, 0xFEDCBA98), cc.data);

    const bend = UmpParser.feed(&.{ 0x40E00000, 0x80000000 }).?.msg.?.pitch_bend;
    try std.testing.expectEqual(@as(u32, 0x80000000), bend.data);
}

test "UMP parser: MIDI 2.0 program change keeps optional bank" {
    const program = UmpParser.feed(&.{ 0x40C00001, 0x2A000105 }).?.msg.?.program_change;
    try std.testing.expectEqual(@as(u7, 42), program.program);
    try std.testing.expectEqual(@as(u7, 1), program.bank.?.msb);
    try std.testing.expectEqual(@as(u7, 5), program.bank.?.lsb);
}

test "UMP parser: reserved packet is skipped at declared boundary" {
    const result = UmpParser.feed(&.{ 0xA0000000, 0xDEADBEEF }).?;
    try std.testing.expectEqual(@as(u3, 2), result.consumed);
    try std.testing.expect(result.msg == null);
}

test "UMP parser: malformed reserved fields are consumed but ignored" {
    const packets = [_][2]u32{
        .{ 0x2090BC40, 0 }, // MIDI 1.0 data byte bit 7
        .{ 0x4090BC00, 0xFFFF0000 }, // note number bit 7
        .{ 0x40B04A01, 0 }, // CC reserved byte
        .{ 0x40E00001, 0x80000000 }, // pitch-bend reserved bits
        .{ 0x40F03C04, 0 }, // per-note management unknown flag
    };
    for (packets) |packet| {
        const result = UmpParser.feed(&packet).?;
        try std.testing.expect(result.msg == null);
    }
}

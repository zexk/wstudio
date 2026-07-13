//! MIDI protocol types, raw-byte parser, and note utilities.
//!
//! Pure protocol layer — no DSP dependency. CC→synth routing lives in
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
/// All state fits in 3 bytes — copy-safe for snapshots.
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
        var i: usize = 0;
        var status = self.running_status;

        if (bytes.len > 0 and bytes[0] & 0x80 != 0) {
            status = bytes[0];
            i = 1;

            // System-realtime: single byte, no running-status update.
            switch (status) {
                // zig fmt: off
                0xF8 => return .{ .msg = .clock,          .consumed = 1 },
                0xFA => return .{ .msg = .start,          .consumed = 1 },
                0xFB => return .{ .msg = .@"continue",    .consumed = 1 },
                0xFC => return .{ .msg = .stop,           .consumed = 1 },
                0xFE => return .{ .msg = .active_sensing, .consumed = 1 },
                0xFF => return .{ .msg = .reset,          .consumed = 1 },
                // zig fmt: on
                else => {},
            }
            if (status < 0xF0) {
                self.running_status = status;
                self.have_d1 = false;
            } else {
                return null; // system-common not implemented
            }
        }

        if (status == 0) return null;

        const kind: u4 = @intCast(status >> 4);
        const ch: Channel = @intCast(status & 0x0F);

        // 1-data-byte messages: program change (0xC), channel pressure (0xD).
        if (kind == 0xC or kind == 0xD) {
            if (i >= bytes.len) return null;
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
            d1 = @intCast(bytes[i] & 0x7F);
            i += 1;
        }

        if (i >= bytes.len) {
            self.d1 = d1;
            self.have_d1 = true;
            return null;
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

    pub fn reset(self: *Parser) void {
        self.* = .{};
    }
};

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
    osc_a_waveform    = 14,  // 0-31=sine  32-63=saw  64-95=tri  96-127=square
    osc_a_pulse_width = 15,  // → pulse_width (0.01–0.99)
    osc_a_unison      = 16,  // → unison count (1–16)
    osc_a_unison_det  = 17,  // → unison_detune cents (0–100)
    osc_a_spread      = 18,  // → unison_spread (0–1)
    osc_b_on          = 20,  // >63 → on
    osc_b_waveform    = 21,  // same mapping as osc_a_waveform
    osc_b_semi        = 22,  // → osc_b_semi (−24..+24 semitones)
    osc_b_detune      = 23,  // → osc_b_detune_cents (−100..+100)
    osc_b_level       = 24,  // → osc_b_level (0–1)
    sub_level         = 25,  // → sub_level (0–1)
    noise_level       = 26,  // → noise_level (0–1)
    noise_color       = 27,  // → noise_color (0=dark … 1=white)
    lfo_rate          = 28,  // → lfo_rate_hz log (0.01–20 Hz)
    lfo_depth_cc      = 29,  // → mod_wheel (0–1), legacy alias of CC 1
    mod_amount        = 30,  // → mod_amount (0–8, covers FM β and AM depth)
    filter_res        = 71,  // GM timbre → filter_res (0–1)
    amp_release       = 72,  // GM release → release_s (0–4 s)
    amp_attack        = 73,  // GM attack → attack_s (0–4 s)
    filter_cutoff     = 74,  // GM brightness → filter_cutoff log (20–18 000 Hz)
    amp_decay         = 75,  // GM decay → decay_s (0–4 s)
    amp_sustain       = 76,  // → sustain level (0–1)
    fenv_amount       = 77,  // retired (fenv amount lives on mod-matrix rows now) — ignored
    fenv_attack       = 78,  // → fenv_attack_s (0–4 s)
    fenv_decay        = 79,  // → fenv_decay_s (0–4 s)
    fenv_sustain      = 80,  // → fenv_sustain (0–1)
    fenv_release      = 81,  // → fenv_release_s (0–4 s)
    all_sound_off     = 120, // GM mandatory — immediate silence
    reset_all_ctrls   = 121, // GM mandatory — no-op for now
    all_notes_off     = 123, // GM mandatory — release all voices
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
    const r = p.feed(&.{ 62, 90 }).?; // no status byte — running status applies
    try std.testing.expect(r.msg == .note_on);
    try std.testing.expectEqual(@as(u7, 62), r.msg.note_on.note);
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

test "noteName: spot checks" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("C4", noteName(60, &buf));
    try std.testing.expectEqualStrings("A4", noteName(69, &buf));
    try std.testing.expectEqualStrings("C-1", noteName(0, &buf));
}

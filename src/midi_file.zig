//! Standard MIDI File (.mid) read/write for the piano-roll pattern (see
//! dsp/pattern.zig) - `:import-midi`/`:export-midi`. Control-thread only, no
//! audio-thread dependency and no relation to the live-stream byte parser in
//! midi.zig (SMF's delta-time + meta/sysex framing doesn't fit that
//! parser's running-status model, notably its reinterpretation of a bare
//! 0xFF as the realtime "reset" message rather than a meta-event marker).
//!
//! Export writes a single-track format-0 file; import accepts format 0 or 1
//! (every track's note events are merged onto one timeline - Note carries no
//! channel/track field, matching the piano roll's single-pattern model).

const std = @import("std");
const pattern_mod = @import("dsp/pattern.zig");
const Note = pattern_mod.Note;

/// Ticks per quarter note used when writing (division field of MThd).
pub const ticks_per_quarter: u16 = 480;

/// Default tempo assumed if a parsed file never sets one (matches General
/// MIDI's default of 120 BPM / 500000 microseconds per quarter note).
pub const default_tempo_bpm: f64 = 120.0;

/// Encode `notes` as a format-0 Standard MIDI File at `tempo_bpm`. Every
/// note becomes a channel-0 note-on/note-off pair; velocity (0-1 float) maps
/// onto the 1-127 MIDI range. Returns an allocator-owned buffer.
pub fn write(allocator: std.mem.Allocator, notes: []const Note, tempo_bpm: f64) ![]u8 {
    var track: std.ArrayListUnmanaged(u8) = .empty;
    defer track.deinit(allocator);

    const mpqn: u32 = @intFromFloat(std.math.clamp(60_000_000.0 / @max(tempo_bpm, 1.0), 1.0, 16_777_215.0));
    try writeVarLen(allocator, &track, 0);
    try track.appendSlice(allocator, &.{ 0xFF, 0x51, 0x03, @intCast(mpqn >> 16), @intCast((mpqn >> 8) & 0xFF), @intCast(mpqn & 0xFF) });

    const Ev = struct { tick: u64, is_off: bool, pitch: u7, vel7: u7 };
    var events: std.ArrayListUnmanaged(Ev) = .empty;
    defer events.deinit(allocator);
    for (notes) |n| {
        const start_tick: u64 = @intFromFloat(@max(0.0, n.start_beat) * @as(f64, @floatFromInt(ticks_per_quarter)));
        const dur_ticks: u64 = @max(1, @as(u64, @intFromFloat(@max(0.0, n.duration_beat) * @as(f64, @floatFromInt(ticks_per_quarter)))));
        const vel7: u7 = @intFromFloat(std.math.clamp(n.velocity, 0.0, 1.0) * 127.0);
        try events.append(allocator, .{ .tick = start_tick, .is_off = false, .pitch = n.pitch, .vel7 = @max(vel7, 1) });
        try events.append(allocator, .{ .tick = start_tick + dur_ticks, .is_off = true, .pitch = n.pitch, .vel7 = 0 });
    }
    std.mem.sort(Ev, events.items, {}, struct {
        fn lessThan(_: void, a: Ev, b: Ev) bool {
            if (a.tick != b.tick) return a.tick < b.tick;
            return a.is_off and !b.is_off; // offs before ons at the same tick
        }
    }.lessThan);

    var prev_tick: u64 = 0;
    for (events.items) |ev| {
        try writeVarLen(allocator, &track, ev.tick - prev_tick);
        prev_tick = ev.tick;
        const status: u8 = if (ev.is_off) 0x80 else 0x90;
        try track.appendSlice(allocator, &.{ status, @intCast(ev.pitch), @intCast(ev.vel7) });
    }
    try writeVarLen(allocator, &track, 0);
    try track.appendSlice(allocator, &.{ 0xFF, 0x2F, 0x00 });

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "MThd");
    try appendU32Be(allocator, &out, 6);
    try appendU16Be(allocator, &out, 0); // format 0
    try appendU16Be(allocator, &out, 1); // ntrks
    try appendU16Be(allocator, &out, ticks_per_quarter);
    try out.appendSlice(allocator, "MTrk");
    try appendU32Be(allocator, &out, @intCast(track.items.len));
    try out.appendSlice(allocator, track.items);
    return out.toOwnedSlice(allocator);
}

fn appendU32Be(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), v: u32) !void {
    try list.appendSlice(allocator, &.{ @intCast(v >> 24), @intCast((v >> 16) & 0xFF), @intCast((v >> 8) & 0xFF), @intCast(v & 0xFF) });
}

fn appendU16Be(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), v: u16) !void {
    try list.appendSlice(allocator, &.{ @intCast(v >> 8), @intCast(v & 0xFF) });
}

/// Standard MIDI variable-length quantity: 7 bits per byte, most-significant
/// group first, every byte but the last has its high bit set.
fn writeVarLen(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), value: u64) !void {
    var buf: [10]u8 = undefined;
    var n: usize = 0;
    var v = value;
    buf[n] = @intCast(v & 0x7F);
    n += 1;
    v >>= 7;
    while (v > 0) {
        buf[n] = @intCast((v & 0x7F) | 0x80);
        n += 1;
        v >>= 7;
    }
    while (n > 0) {
        n -= 1;
        try list.append(allocator, buf[n]);
    }
}

pub const ParseError = error{
    InvalidHeader,
    UnsupportedDivision,
    OutOfMemory,
    Truncated,
};

pub const ParseResult = struct {
    /// Allocator-owned, sorted by start_beat. Caller frees.
    notes: []Note,
    length_beats: f64,
    /// The first Set Tempo meta event found across every track, or
    /// `default_tempo_bpm` if the file never set one.
    tempo_bpm: f64,
    /// True if the file had more notes than `pattern_mod.max_notes` and the
    /// tail (by start time) was dropped.
    truncated: bool,
};

/// Parse a format-0/1 Standard MIDI File, merging every track's note events
/// onto one timeline (see the file's top doc comment for why).
pub fn parse(allocator: std.mem.Allocator, data: []const u8) ParseError!ParseResult {
    if (data.len < 14 or !std.mem.eql(u8, data[0..4], "MThd")) return error.InvalidHeader;
    const header_len = readU32Be(data[4..8]);
    if (header_len < 6 or data.len < 8 + header_len) return error.InvalidHeader;
    const ntrks = readU16Be(data[10..12]);
    const division = readU16Be(data[12..14]);
    if (division & 0x8000 != 0) return error.UnsupportedDivision; // SMPTE, not supported
    const ticks_per_beat: f64 = @floatFromInt(division);

    var notes: std.ArrayListUnmanaged(Note) = .empty;
    errdefer notes.deinit(allocator);
    var tempo_bpm: ?f64 = null;

    var pos: usize = 8 + header_len;
    var track_i: usize = 0;
    while (track_i < ntrks and pos + 8 <= data.len) : (track_i += 1) {
        if (!std.mem.eql(u8, data[pos .. pos + 4], "MTrk")) return error.InvalidHeader;
        const track_len = readU32Be(data[pos + 4 .. pos + 8]);
        const track_start = pos + 8;
        if (track_start + track_len > data.len) return error.Truncated;
        const track_end = track_start + track_len;
        try parseTrack(allocator, data[track_start..track_end], ticks_per_beat, &notes, &tempo_bpm);
        pos = track_end;
    }

    std.mem.sort(Note, notes.items, {}, struct {
        fn lessThan(_: void, a: Note, b: Note) bool {
            return a.start_beat < b.start_beat;
        }
    }.lessThan);

    var truncated = false;
    if (notes.items.len > pattern_mod.max_notes) {
        truncated = true;
        notes.shrinkRetainingCapacity(pattern_mod.max_notes);
    }

    var length_beats: f64 = 1.0;
    for (notes.items) |n| length_beats = @max(length_beats, n.start_beat + n.duration_beat);

    return .{
        .notes = try notes.toOwnedSlice(allocator),
        .length_beats = length_beats,
        .tempo_bpm = tempo_bpm orelse default_tempo_bpm,
        .truncated = truncated,
    };
}

fn parseTrack(
    allocator: std.mem.Allocator,
    track: []const u8,
    ticks_per_beat: f64,
    notes: *std.ArrayListUnmanaged(Note),
    tempo_bpm: *?f64,
) ParseError!void {
    // Currently-held note per (channel, pitch): its start tick and note-on
    // velocity. MIDI files don't nest same-pitch note-ons, but a stray
    // double note-on (no note-off between them) is retriggered: close the
    // first at the second's tick rather than losing it.
    const Held = struct { start: u64, vel7: u8 };
    var active: [16][128]?Held = [_][128]?Held{[_]?Held{null} ** 128} ** 16;

    var pos: usize = 0;
    var tick: u64 = 0;
    var running_status: u8 = 0;
    var last_tick: u64 = 0;
    while (pos < track.len) {
        const delta = try readVarLen(track, &pos);
        tick += delta;
        last_tick = tick;
        if (pos >= track.len) break;
        const first = track[pos];

        if (first == 0xFF) { // meta event
            pos += 1;
            if (pos >= track.len) break;
            const meta_type = track[pos];
            pos += 1;
            const len = try readVarLen(track, &pos);
            if (pos + len > track.len) return error.Truncated;
            if (meta_type == 0x51 and len == 3) {
                const mpqn = (@as(u32, track[pos]) << 16) | (@as(u32, track[pos + 1]) << 8) | track[pos + 2];
                if (tempo_bpm.* == null and mpqn > 0) tempo_bpm.* = 60_000_000.0 / @as(f64, @floatFromInt(mpqn));
            }
            pos += len;
            continue;
        }
        if (first == 0xF0 or first == 0xF7) { // sysex
            pos += 1;
            const len = try readVarLen(track, &pos);
            if (pos + len > track.len) return error.Truncated;
            pos += len;
            continue;
        }

        var status = running_status;
        if (first & 0x80 != 0) {
            status = first;
            pos += 1;
        }
        if (status < 0x80 or status >= 0xF0) return error.InvalidHeader; // unrecognised/unsupported status
        running_status = status;
        const kind: u4 = @intCast(status >> 4);
        const ch: u4 = @intCast(status & 0x0F);
        const n_data: usize = if (kind == 0xC or kind == 0xD) 1 else 2;
        if (pos + n_data > track.len) return error.Truncated;
        const d1 = track[pos] & 0x7F;
        const d2: u8 = if (n_data == 2) track[pos + 1] & 0x7F else 0;
        pos += n_data;

        switch (kind) {
            0x9 => { // note on (velocity 0 == note off)
                if (d2 == 0) {
                    try closeNote(allocator, notes, &active, ch, d1, tick, ticks_per_beat);
                } else {
                    if (active[ch][d1] != null) try closeNote(allocator, notes, &active, ch, d1, tick, ticks_per_beat);
                    active[ch][d1] = .{ .start = tick, .vel7 = d2 };
                }
            },
            0x8 => try closeNote(allocator, notes, &active, ch, d1, tick, ticks_per_beat),
            else => {}, // aftertouch/CC/program-change/pitch-bend: not part of the pattern model
        }
    }

    // Dangling note-ons (missing note-off): close at the track's last tick.
    for (0..16) |ch| for (0..128) |pitch| {
        if (active[ch][pitch]) |held| {
            active[ch][pitch] = null;
            const dur_ticks = @max(1, last_tick -| held.start);
            notes.append(allocator, .{
                .pitch = @intCast(pitch),
                .start_beat = @as(f64, @floatFromInt(held.start)) / ticks_per_beat,
                .duration_beat = @as(f64, @floatFromInt(dur_ticks)) / ticks_per_beat,
                .velocity = @as(f32, @floatFromInt(held.vel7)) / 127.0,
            }) catch return error.OutOfMemory;
        }
    };
}

fn closeNote(
    allocator: std.mem.Allocator,
    notes: *std.ArrayListUnmanaged(Note),
    active: anytype,
    ch: u4,
    pitch: u8,
    tick: u64,
    ticks_per_beat: f64,
) !void {
    const held = active[ch][pitch] orelse return;
    active[ch][pitch] = null;
    const dur_ticks = @max(1, tick -| held.start);
    try notes.append(allocator, .{
        .pitch = @intCast(pitch),
        .start_beat = @as(f64, @floatFromInt(held.start)) / ticks_per_beat,
        .duration_beat = @as(f64, @floatFromInt(dur_ticks)) / ticks_per_beat,
        .velocity = @as(f32, @floatFromInt(held.vel7)) / 127.0,
    });
}

/// Matches `writeVarLen`'s full `u64` range (10 groups of 7 bits) rather
/// than the standard's usual 4-byte/28-bit delta-time convention, so a
/// pattern wide enough to need a multi-byte-past-28-bit delta still
/// round-trips through our own writer.
fn readVarLen(data: []const u8, pos: *usize) ParseError!u64 {
    var value: u64 = 0;
    var i: usize = 0;
    while (true) {
        if (pos.* >= data.len or i >= 10) return error.Truncated;
        const b = data[pos.*];
        pos.* += 1;
        i += 1;
        value = (value << 7) | (b & 0x7F);
        if (b & 0x80 == 0) break;
    }
    return value;
}

fn readU32Be(b: []const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}

fn readU16Be(b: []const u8) u16 {
    return (@as(u16, b[0]) << 8) | b[1];
}

test "write then parse round-trips notes, tempo, and length" {
    const allocator = std.testing.allocator;
    const notes = [_]Note{
        .{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0, .velocity = 1.0 },
        .{ .pitch = 64, .start_beat = 1.0, .duration_beat = 0.5, .velocity = 0.5 },
        .{ .pitch = 67, .start_beat = 1.5, .duration_beat = 2.0, .velocity = 0.25 },
    };
    const bytes = try write(allocator, &notes, 140.0);
    defer allocator.free(bytes);

    const result = try parse(allocator, bytes);
    defer allocator.free(result.notes);
    try std.testing.expectEqual(@as(usize, 3), result.notes.len);
    try std.testing.expectApproxEqAbs(@as(f64, 140.0), result.tempo_bpm, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), result.length_beats, 0.01);
    try std.testing.expect(!result.truncated);

    try std.testing.expectEqual(@as(u7, 60), result.notes[0].pitch);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.notes[0].start_beat, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.notes[0].duration_beat, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result.notes[0].velocity, 0.02);

    try std.testing.expectEqual(@as(u7, 67), result.notes[2].pitch);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), result.notes[2].start_beat, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.notes[2].duration_beat, 0.01);
}

test "write then parse round-trips a note far enough out to need a delta-time past the standard 4-byte VLQ" {
    const allocator = std.testing.allocator;
    // 1,000,000 beats * 480 ticks/beat needs a 5-byte VLQ (> 2^28).
    const notes = [_]Note{.{ .pitch = 60, .start_beat = 1_000_000.0, .duration_beat = 1.0 }};
    const bytes = try write(allocator, &notes, 120.0);
    defer allocator.free(bytes);

    const result = try parse(allocator, bytes);
    defer allocator.free(result.notes);
    try std.testing.expectEqual(@as(usize, 1), result.notes.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1_000_000.0), result.notes[0].start_beat, 0.01);
}

test "parse rejects a file without an MThd header" {
    try std.testing.expectError(error.InvalidHeader, parse(std.testing.allocator, "not a midi file"));
}

test "parse handles a format-1 file with tracks split across channels, merging both onto one timeline" {
    const allocator = std.testing.allocator;
    // Two single-note tracks (format 1), channel 0 and channel 1.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "MThd");
    try appendU32Be(allocator, &buf, 6);
    try appendU16Be(allocator, &buf, 1); // format 1
    try appendU16Be(allocator, &buf, 2); // ntrks
    try appendU16Be(allocator, &buf, 480);

    // Track 0: tempo + note on ch0 pitch 60, then off.
    try buf.appendSlice(allocator, "MTrk");
    try appendU32Be(allocator, &buf, 12);
    try buf.appendSlice(allocator, &.{ 0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20 }); // 120 BPM
    try buf.appendSlice(allocator, &.{ 0x00, 0x90, 60, 100 });
    try buf.appendSlice(allocator, &.{ 0x00, 0xFF, 0x2F, 0x00 });
    // Fix up track 0's length (7 + 4 + 3 = wrong above; recompute properly).
    // Simpler: rebuild with explicit correct length below instead.
    buf.shrinkRetainingCapacity(0);
    try buf.appendSlice(allocator, "MThd");
    try appendU32Be(allocator, &buf, 6);
    try appendU16Be(allocator, &buf, 1);
    try appendU16Be(allocator, &buf, 2);
    try appendU16Be(allocator, &buf, 480);

    var t0: std.ArrayListUnmanaged(u8) = .empty;
    defer t0.deinit(allocator);
    try t0.appendSlice(allocator, &.{ 0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20 });
    try t0.appendSlice(allocator, &.{ 0x00, 0x90, 60, 100 });
    try t0.appendSlice(allocator, &.{ 0x78, 0x80, 60, 0 }); // note off after 120 ticks
    try t0.appendSlice(allocator, &.{ 0x00, 0xFF, 0x2F, 0x00 });
    try buf.appendSlice(allocator, "MTrk");
    try appendU32Be(allocator, &buf, @intCast(t0.items.len));
    try buf.appendSlice(allocator, t0.items);

    var t1: std.ArrayListUnmanaged(u8) = .empty;
    defer t1.deinit(allocator);
    try t1.appendSlice(allocator, &.{ 0x00, 0x91, 64, 90 }); // ch1 note on
    try t1.appendSlice(allocator, &.{ 0xF0, 0x03, 0x81, 0x00, 0x00 }); // note off after 480 ticks (VLQ)
    try t1.appendSlice(allocator, &.{ 0x00, 0xFF, 0x2F, 0x00 });
    try buf.appendSlice(allocator, "MTrk");
    try appendU32Be(allocator, &buf, @intCast(t1.items.len));
    try buf.appendSlice(allocator, t1.items);

    const result = try parse(allocator, buf.items);
    defer allocator.free(result.notes);
    try std.testing.expectEqual(@as(usize, 2), result.notes.len);
    try std.testing.expectApproxEqAbs(@as(f64, 120.0), result.tempo_bpm, 0.01);
    try std.testing.expectEqual(@as(u7, 60), result.notes[0].pitch);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), result.notes[0].duration_beat, 0.01);
    try std.testing.expectEqual(@as(u7, 64), result.notes[1].pitch);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.notes[1].start_beat, 0.01);
}

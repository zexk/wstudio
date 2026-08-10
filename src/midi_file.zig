//! Standard MIDI File (.mid) read/write for the piano-roll pattern (see
//! dsp/pattern.zig) - `:import-midi`/`:export-midi`. Control-thread only, no
//! audio-thread dependency and no relation to the live-stream byte parser in
//! midi.zig (SMF's delta-time + meta/sysex framing doesn't fit that
//! parser's running-status model, notably its reinterpretation of a bare
//! 0xFF as the realtime "reset" message rather than a meta-event marker).
//!
//! Export writes format 1 when full event fidelity is requested; import
//! accepts format 0 or 1 and retains source track and channel identity.

const std = @import("std");
const pattern_mod = @import("dsp/pattern.zig");
const Note = pattern_mod.Note;
const MidiEvent = pattern_mod.MidiEvent;
const time_map = @import("time_map.zig");

/// Ticks per quarter note used when writing (division field of MThd).
pub const ticks_per_quarter: u16 = 480;

/// Default tempo assumed if a parsed file never sets one (matches General
/// MIDI's default of 120 BPM / 500000 microseconds per quarter note).
pub const default_tempo_bpm: f64 = 120.0;

/// Encode `notes` as a format-0 Standard MIDI File at `tempo_bpm`. Every
/// note becomes a note-on/note-off pair; velocity (0-1 float) maps
/// onto the 1-127 MIDI range. Returns an allocator-owned buffer.
///
/// Per-note expression (`Note.art` - pan, fine tuning, release) is
/// deliberately dropped rather than approximated. Every MIDI vehicle for
/// those is per *channel*, not per note (CC10, pitch bend, CC72), so on a
/// single channel a chord's notes would overwrite each other's settings and
/// the last one written would win for all of them - silently wrong in a way
/// that only shows up on polyphonic material. Carrying it needs MPE, one
/// channel per sounding note, which is a different file to write. An import
/// likewise leaves every note neutral.
pub fn write(allocator: std.mem.Allocator, notes: []const Note, tempo_bpm: f64) ![]u8 {
    var track: std.ArrayListUnmanaged(u8) = .empty;
    defer track.deinit(allocator);

    const safe_tempo = if (std.math.isFinite(tempo_bpm) and tempo_bpm > 0) tempo_bpm else default_tempo_bpm;
    const mpqn: u32 = @intFromFloat(std.math.clamp(60_000_000.0 / safe_tempo, 1.0, 16_777_215.0));
    try writeVarLen(allocator, &track, 0);
    try track.appendSlice(allocator, &.{ 0xFF, 0x51, 0x03, @intCast(mpqn >> 16), @intCast((mpqn >> 8) & 0xFF), @intCast(mpqn & 0xFF) });

    const Ev = struct { tick: u64, is_off: bool, pitch: u7, vel7: u7 };
    var events: std.ArrayListUnmanaged(Ev) = .empty;
    defer events.deinit(allocator);
    for (notes) |n| {
        const start_tick = beatToTick(n.start_beat);
        const dur_ticks = @max(1, beatToTick(n.duration_beat));
        const velocity = if (std.math.isFinite(n.velocity)) n.velocity else 1.0;
        const vel7: u7 = @intFromFloat(std.math.clamp(velocity, 0.0, 1.0) * 127.0);
        try events.append(allocator, .{ .tick = start_tick, .is_off = false, .pitch = n.pitch, .vel7 = @max(vel7, 1) });
        try events.append(allocator, .{ .tick = start_tick +| dur_ticks, .is_off = true, .pitch = n.pitch, .vel7 = 0 });
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

const WriteEvent = struct {
    tick: u64,
    order: u8,
    bytes: [3]u8,
    len: u2,
};

pub fn writeProject(allocator: std.mem.Allocator, notes: []const Note, midi_events: []const MidiEvent, tempo_points: []const time_map.TempoPoint, tempo_bpm: f64) ![]u8 {
    var max_track: u16 = 0;
    for (notes) |note| max_track = @max(max_track, note.midi_track);
    for (midi_events) |event| max_track = @max(max_track, event.midi_track);
    const track_count: u16 = max_track +| 2;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "MThd");
    try appendU32Be(allocator, &out, 6);
    try appendU16Be(allocator, &out, 1);
    try appendU16Be(allocator, &out, track_count);
    try appendU16Be(allocator, &out, ticks_per_quarter);

    var tempo_track: std.ArrayListUnmanaged(u8) = .empty;
    defer tempo_track.deinit(allocator);
    try appendTempo(allocator, &tempo_track, 0, tempo_bpm);
    var previous_tick: u64 = 0;
    for (tempo_points) |point| {
        const tick = beatToTick(point.beat);
        if (tick == 0) continue;
        try appendTempo(allocator, &tempo_track, tick - previous_tick, point.bpm);
        previous_tick = tick;
    }
    try finishTrack(allocator, &tempo_track);
    try appendTrackChunk(allocator, &out, tempo_track.items);

    var midi_track: u16 = 0;
    while (midi_track <= max_track) : (midi_track += 1) {
        var events: std.ArrayListUnmanaged(WriteEvent) = .empty;
        defer events.deinit(allocator);
        for (notes) |note| {
            if (note.midi_track != midi_track) continue;
            const tick = beatToTick(note.start_beat);
            const velocity: u7 = @intFromFloat(std.math.clamp(note.velocity, 0.0, 1.0) * 127.0);
            try events.append(allocator, .{ .tick = tick, .order = 1, .bytes = .{ 0x90 | @as(u8, note.channel), note.pitch, @max(velocity, 1) }, .len = 3 });
            try events.append(allocator, .{ .tick = tick +| @max(1, beatToTick(note.duration_beat)), .order = 0, .bytes = .{ 0x80 | @as(u8, note.channel), note.pitch, 0 }, .len = 3 });
        }
        for (midi_events) |event| {
            if (event.midi_track != midi_track) continue;
            const status_channel: u8 = event.channel;
            const write_event: WriteEvent = switch (event.data) {
                .cc => |cc| .{ .tick = beatToTick(event.beat), .order = 2, .bytes = .{ 0xB0 | status_channel, cc.controller, cc.value }, .len = 3 },
                .program_change => |program| .{ .tick = beatToTick(event.beat), .order = 2, .bytes = .{ 0xC0 | status_channel, program, 0 }, .len = 2 },
                .channel_pressure => |pressure| .{ .tick = beatToTick(event.beat), .order = 2, .bytes = .{ 0xD0 | status_channel, pressure, 0 }, .len = 2 },
                .poly_pressure => |pressure| .{ .tick = beatToTick(event.beat), .order = 2, .bytes = .{ 0xA0 | status_channel, pressure.pitch, pressure.pressure }, .len = 3 },
                .pitch_bend => |bend| .{ .tick = beatToTick(event.beat), .order = 2, .bytes = .{ 0xE0 | status_channel, @intCast(bend & 0x7F), @intCast(bend >> 7) }, .len = 3 },
            };
            try events.append(allocator, write_event);
        }
        std.mem.sort(WriteEvent, events.items, {}, struct {
            fn lessThan(_: void, a: WriteEvent, b: WriteEvent) bool {
                return a.tick < b.tick or (a.tick == b.tick and a.order < b.order);
            }
        }.lessThan);
        var track: std.ArrayListUnmanaged(u8) = .empty;
        defer track.deinit(allocator);
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "wstudio-track:{d}", .{midi_track});
        try writeVarLen(allocator, &track, 0);
        try track.appendSlice(allocator, &.{ 0xFF, 0x03 });
        try writeVarLen(allocator, &track, name.len);
        try track.appendSlice(allocator, name);
        previous_tick = 0;
        for (events.items) |event| {
            try writeVarLen(allocator, &track, event.tick - previous_tick);
            try track.appendSlice(allocator, event.bytes[0..event.len]);
            previous_tick = event.tick;
        }
        try finishTrack(allocator, &track);
        try appendTrackChunk(allocator, &out, track.items);
    }
    return out.toOwnedSlice(allocator);
}

fn appendTempo(allocator: std.mem.Allocator, track: *std.ArrayListUnmanaged(u8), delta: u64, bpm: f64) !void {
    const safe = if (std.math.isFinite(bpm) and bpm > 0) bpm else default_tempo_bpm;
    const mpqn: u32 = @intFromFloat(std.math.clamp(60_000_000.0 / safe, 1.0, 16_777_215.0));
    try writeVarLen(allocator, track, delta);
    try track.appendSlice(allocator, &.{ 0xFF, 0x51, 0x03, @intCast(mpqn >> 16), @intCast((mpqn >> 8) & 0xFF), @intCast(mpqn & 0xFF) });
}

fn finishTrack(allocator: std.mem.Allocator, track: *std.ArrayListUnmanaged(u8)) !void {
    try writeVarLen(allocator, track, 0);
    try track.appendSlice(allocator, &.{ 0xFF, 0x2F, 0 });
}

fn appendTrackChunk(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), track: []const u8) !void {
    try out.appendSlice(allocator, "MTrk");
    try appendU32Be(allocator, out, @intCast(track.len));
    try out.appendSlice(allocator, track);
}

fn beatToTick(beat: f64) u64 {
    if (!std.math.isFinite(beat) or beat <= 0) return if (std.math.isPositiveInf(beat)) std.math.maxInt(u64) else 0;
    const scaled = beat * @as(f64, @floatFromInt(ticks_per_quarter));
    if (!std.math.isFinite(scaled) or scaled >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return std.math.maxInt(u64);
    return @intFromFloat(scaled);
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
    tempo_points: []time_map.TempoPoint,
    events: []MidiEvent,
    /// True if the file had more notes than `pattern_mod.max_notes` and the
    /// tail (by start time) was dropped.
    truncated: bool,

    pub fn deinit(self: ParseResult, allocator: std.mem.Allocator) void {
        allocator.free(self.notes);
        allocator.free(self.tempo_points);
        allocator.free(self.events);
    }
};

/// Parse a format-0/1 Standard MIDI File, merging every track's note events
/// onto one timeline (see the file's top doc comment for why).
pub fn parse(allocator: std.mem.Allocator, data: []const u8) ParseError!ParseResult {
    if (data.len < 14 or !std.mem.eql(u8, data[0..4], "MThd")) return error.InvalidHeader;
    const header_len = readU32Be(data[4..8]);
    if (header_len < 6 or data.len < 8 + header_len) return error.InvalidHeader;
    const format = readU16Be(data[8..10]);
    const ntrks = readU16Be(data[10..12]);
    if (format > 1 or ntrks == 0 or (format == 0 and ntrks != 1)) return error.InvalidHeader;
    const division = readU16Be(data[12..14]);
    if (division & 0x8000 != 0 or division == 0) return error.UnsupportedDivision; // SMPTE or zero, not supported
    const ticks_per_beat: f64 = @floatFromInt(division);

    var notes: std.ArrayListUnmanaged(Note) = .empty;
    errdefer notes.deinit(allocator);
    var events: std.ArrayListUnmanaged(MidiEvent) = .empty;
    errdefer events.deinit(allocator);
    var tempo_points: std.ArrayListUnmanaged(time_map.TempoPoint) = .empty;
    errdefer tempo_points.deinit(allocator);
    var tempo_bpm: ?f64 = null;

    var pos: usize = 8 + header_len;
    var track_i: usize = 0;
    while (track_i < ntrks and pos + 8 <= data.len) : (track_i += 1) {
        if (!std.mem.eql(u8, data[pos .. pos + 4], "MTrk")) return error.InvalidHeader;
        const track_len = readU32Be(data[pos + 4 .. pos + 8]);
        const track_start = pos + 8;
        if (track_start + track_len > data.len) return error.Truncated;
        const track_end = track_start + track_len;
        try parseTrack(allocator, data[track_start..track_end], ticks_per_beat, @intCast(track_i), &notes, &events, &tempo_points, &tempo_bpm);
        pos = track_end;
    }
    if (track_i != ntrks) return error.Truncated;

    std.mem.sort(Note, notes.items, {}, struct {
        fn lessThan(_: void, a: Note, b: Note) bool {
            return a.start_beat < b.start_beat;
        }
    }.lessThan);
    std.mem.sort(MidiEvent, events.items, {}, struct {
        fn lessThan(_: void, a: MidiEvent, b: MidiEvent) bool {
            return a.beat < b.beat;
        }
    }.lessThan);
    std.mem.sort(time_map.TempoPoint, tempo_points.items, {}, struct {
        fn lessThan(_: void, a: time_map.TempoPoint, b: time_map.TempoPoint) bool {
            return a.beat < b.beat;
        }
    }.lessThan);

    var truncated = false;
    if (notes.items.len > pattern_mod.max_notes) {
        truncated = true;
        notes.shrinkRetainingCapacity(pattern_mod.max_notes);
    }
    if (events.items.len > pattern_mod.max_midi_events) {
        truncated = true;
        events.shrinkRetainingCapacity(pattern_mod.max_midi_events);
    }

    var length_beats: f64 = 1.0;
    for (notes.items) |n| length_beats = @max(length_beats, n.start_beat + n.duration_beat);

    // Each `toOwnedSlice` empties the list it took from, so that list's own
    // errdefer above stops covering the memory - the next one that fails
    // would drop the only pointer to what the previous ones handed over.
    const owned_notes = try notes.toOwnedSlice(allocator);
    errdefer allocator.free(owned_notes);
    const owned_tempo_points = try tempo_points.toOwnedSlice(allocator);
    errdefer allocator.free(owned_tempo_points);
    return .{
        .notes = owned_notes,
        .length_beats = length_beats,
        .tempo_bpm = tempo_bpm orelse default_tempo_bpm,
        .tempo_points = owned_tempo_points,
        .events = try events.toOwnedSlice(allocator),
        .truncated = truncated,
    };
}

fn parseTrack(
    allocator: std.mem.Allocator,
    track: []const u8,
    ticks_per_beat: f64,
    midi_track: u16,
    notes: *std.ArrayListUnmanaged(Note),
    events: *std.ArrayListUnmanaged(MidiEvent),
    tempo_points: *std.ArrayListUnmanaged(time_map.TempoPoint),
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
    var source_track = midi_track;
    while (pos < track.len) {
        const delta = try readVarLen(track, &pos);
        tick = std.math.add(u64, tick, delta) catch return error.InvalidHeader;
        last_tick = tick;
        if (pos >= track.len) return error.Truncated;
        const first = track[pos];

        if (first == 0xFF) { // meta event
            running_status = 0;
            pos += 1;
            if (pos >= track.len) return error.Truncated;
            const meta_type = track[pos];
            pos += 1;
            const len = try readVarLen(track, &pos);
            if (len > track.len - pos) return error.Truncated;
            const event_len: usize = @intCast(len);
            if (meta_type == 0x51 and len == 3) {
                const mpqn = (@as(u32, track[pos]) << 16) | (@as(u32, track[pos + 1]) << 8) | track[pos + 2];
                if (mpqn > 0) {
                    const bpm = 60_000_000.0 / @as(f64, @floatFromInt(mpqn));
                    if (tempo_bpm.* == null) tempo_bpm.* = bpm;
                    tempo_points.append(allocator, .{ .beat = @as(f64, @floatFromInt(tick)) / ticks_per_beat, .bpm = bpm }) catch return error.OutOfMemory;
                }
            } else if (meta_type == 0x03 and std.mem.startsWith(u8, track[pos .. pos + event_len], "wstudio-track:")) {
                source_track = std.fmt.parseInt(u16, track[pos + 14 .. pos + event_len], 10) catch midi_track;
            }
            pos += event_len;
            continue;
        }
        if (first == 0xF0 or first == 0xF7) { // sysex
            running_status = 0;
            pos += 1;
            const len = try readVarLen(track, &pos);
            if (len > track.len - pos) return error.Truncated;
            pos += @intCast(len);
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
        if (track[pos] & 0x80 != 0 or (n_data == 2 and track[pos + 1] & 0x80 != 0)) return error.InvalidHeader;
        const d1 = track[pos];
        const d2: u8 = if (n_data == 2) track[pos + 1] else 0;
        pos += n_data;

        switch (kind) {
            0x9 => { // note on (velocity 0 == note off)
                if (d2 == 0) {
                    try closeNote(allocator, notes, &active, source_track, ch, d1, tick, ticks_per_beat);
                } else {
                    if (active[ch][d1] != null) try closeNote(allocator, notes, &active, source_track, ch, d1, tick, ticks_per_beat);
                    active[ch][d1] = .{ .start = tick, .vel7 = d2 };
                }
            },
            0x8 => try closeNote(allocator, notes, &active, source_track, ch, d1, tick, ticks_per_beat),
            0xA => try events.append(allocator, .{ .beat = @as(f64, @floatFromInt(tick)) / ticks_per_beat, .midi_track = source_track, .channel = ch, .data = .{ .poly_pressure = .{ .pitch = @intCast(d1), .pressure = @intCast(d2) } } }),
            0xB => try events.append(allocator, .{ .beat = @as(f64, @floatFromInt(tick)) / ticks_per_beat, .midi_track = source_track, .channel = ch, .data = .{ .cc = .{ .controller = @intCast(d1), .value = @intCast(d2) } } }),
            0xC => try events.append(allocator, .{ .beat = @as(f64, @floatFromInt(tick)) / ticks_per_beat, .midi_track = source_track, .channel = ch, .data = .{ .program_change = @intCast(d1) } }),
            0xD => try events.append(allocator, .{ .beat = @as(f64, @floatFromInt(tick)) / ticks_per_beat, .midi_track = source_track, .channel = ch, .data = .{ .channel_pressure = @intCast(d1) } }),
            0xE => try events.append(allocator, .{ .beat = @as(f64, @floatFromInt(tick)) / ticks_per_beat, .midi_track = source_track, .channel = ch, .data = .{ .pitch_bend = @as(u14, d1) | (@as(u14, d2) << 7) } }),
            else => {},
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
                .channel = @intCast(ch),
                .midi_track = source_track,
            }) catch return error.OutOfMemory;
        }
    };
}

fn closeNote(
    allocator: std.mem.Allocator,
    notes: *std.ArrayListUnmanaged(Note),
    active: anytype,
    midi_track: u16,
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
        .channel = ch,
        .midi_track = midi_track,
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
        const payload: u64 = b & 0x7F;
        if (value > (std.math.maxInt(u64) - payload) >> 7) return error.InvalidHeader;
        value = (value << 7) | payload;
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
    defer result.deinit(allocator);
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
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.notes.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1_000_000.0), result.notes[0].start_beat, 0.01);
}

test "write sanitizes non-finite tempo and note fields" {
    const allocator = std.testing.allocator;
    const notes = [_]Note{.{
        .pitch = 60,
        .start_beat = std.math.nan(f64),
        .duration_beat = std.math.nan(f64),
        .velocity = std.math.nan(f32),
    }};
    const bytes = try write(allocator, &notes, std.math.nan(f64));
    defer allocator.free(bytes);

    const result = try parse(allocator, bytes);
    defer result.deinit(allocator);
    try std.testing.expectApproxEqAbs(default_tempo_bpm, result.tempo_bpm, 0.01);
    try std.testing.expectEqual(@as(usize, 1), result.notes.len);
    try std.testing.expectEqual(@as(f64, 0), result.notes[0].start_beat);
    try std.testing.expectApproxEqAbs(1.0 / @as(f64, @floatFromInt(ticks_per_quarter)), result.notes[0].duration_beat, 0.0001);
    try std.testing.expectEqual(@as(f32, 1), result.notes[0].velocity);
}

test "parse rejects a file without an MThd header" {
    try std.testing.expectError(error.InvalidHeader, parse(std.testing.allocator, "not a midi file"));
}

test "parse rejects unsupported format and invalid track counts" {
    try std.testing.expectError(error.InvalidHeader, parse(std.testing.allocator, "MThd\x00\x00\x00\x06\x00\x02\x00\x01\x01\xe0"));
    try std.testing.expectError(error.InvalidHeader, parse(std.testing.allocator, "MThd\x00\x00\x00\x06\x00\x00\x00\x02\x01\xe0"));
    try std.testing.expectError(error.InvalidHeader, parse(std.testing.allocator, "MThd\x00\x00\x00\x06\x00\x01\x00\x00\x01\xe0"));
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
    try t1.appendSlice(allocator, &.{ 0x83, 0x60, 0x81, 64, 0 }); // note off after 480 ticks (two-byte VLQ)
    try t1.appendSlice(allocator, &.{ 0x00, 0xFF, 0x2F, 0x00 });
    try buf.appendSlice(allocator, "MTrk");
    try appendU32Be(allocator, &buf, @intCast(t1.items.len));
    try buf.appendSlice(allocator, t1.items);

    const result = try parse(allocator, buf.items);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.notes.len);
    try std.testing.expectApproxEqAbs(@as(f64, 120.0), result.tempo_bpm, 0.01);
    try std.testing.expectEqual(@as(u7, 60), result.notes[0].pitch);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), result.notes[0].duration_beat, 0.01);
    try std.testing.expectEqual(@as(u7, 64), result.notes[1].pitch);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.notes[1].start_beat, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.notes[1].duration_beat, 0.01);
}

test "format-1 export round-trips channels tracks events and tempo map" {
    const allocator = std.testing.allocator;
    const bytes = try writeProject(allocator, &.{
        .{ .pitch = 60, .start_beat = 0, .duration_beat = 1, .channel = 2, .midi_track = 0 },
        .{ .pitch = 64, .start_beat = 1, .duration_beat = 1, .channel = 7, .midi_track = 3 },
    }, &.{
        .{ .beat = 0.5, .midi_track = 3, .channel = 7, .data = .{ .cc = .{ .controller = 74, .value = 99 } } },
        .{ .beat = 1.5, .midi_track = 0, .channel = 2, .data = .{ .pitch_bend = 12_000 } },
    }, &.{.{ .beat = 2, .bpm = 90 }}, 120);
    defer allocator.free(bytes);
    const result = try parse(allocator, bytes);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.notes.len);
    try std.testing.expectEqual(@as(u4, 2), result.notes[0].channel);
    try std.testing.expectEqual(@as(u16, 0), result.notes[0].midi_track);
    try std.testing.expectEqual(@as(u4, 7), result.notes[1].channel);
    try std.testing.expectEqual(@as(u16, 3), result.notes[1].midi_track);
    try std.testing.expectEqual(@as(usize, 2), result.events.len);
    try std.testing.expectEqual(@as(usize, 2), result.tempo_points.len);
    try std.testing.expectApproxEqAbs(@as(f64, 90), result.tempo_points[1].bpm, 0.01);
}

test "parse rejects a zero division field" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "MThd");
    try appendU32Be(allocator, &buf, 6);
    try appendU16Be(allocator, &buf, 0); // format 0
    try appendU16Be(allocator, &buf, 1); // ntrks
    try appendU16Be(allocator, &buf, 0); // division 0 - would zero every tick-to-beat divide
    try std.testing.expectError(error.UnsupportedDivision, parse(allocator, buf.items));
}

test "parse rejects cumulative delta-time overflow" {
    const allocator = std.testing.allocator;
    var track: std.ArrayListUnmanaged(u8) = .empty;
    defer track.deinit(allocator);
    try writeVarLen(allocator, &track, std.math.maxInt(u64));
    try track.appendSlice(allocator, &.{ 0xC0, 0x00 });
    try writeVarLen(allocator, &track, 1);
    try track.appendSlice(allocator, &.{ 0xC0, 0x00 });

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "MThd");
    try appendU32Be(allocator, &buf, 6);
    try appendU16Be(allocator, &buf, 0);
    try appendU16Be(allocator, &buf, 1);
    try appendU16Be(allocator, &buf, ticks_per_quarter);
    try buf.appendSlice(allocator, "MTrk");
    try appendU32Be(allocator, &buf, @intCast(track.items.len));
    try buf.appendSlice(allocator, track.items);

    try std.testing.expectError(error.InvalidHeader, parse(allocator, buf.items));
}

test "parse rejects fewer tracks than header declares" {
    const file = "MThd\x00\x00\x00\x06\x00\x00\x00\x01\x01\xe0";
    try std.testing.expectError(error.Truncated, parse(std.testing.allocator, file));
}

test "parse rejects incomplete event at track end" {
    const file = "MThd\x00\x00\x00\x06\x00\x00\x00\x01\x01\xe0" ++
        "MTrk\x00\x00\x00\x02\x00\xff";
    try std.testing.expectError(error.Truncated, parse(std.testing.allocator, file));
}

test "parse rejects status bytes inside channel data" {
    const file = "MThd\x00\x00\x00\x06\x00\x00\x00\x01\x01\xe0" ++
        "MTrk\x00\x00\x00\x04\x00\x90\x3c\x80";
    try std.testing.expectError(error.InvalidHeader, parse(std.testing.allocator, file));
}

test "SysEx and meta events cancel running status" {
    const sysex = "MThd\x00\x00\x00\x06\x00\x00\x00\x01\x01\xe0" ++
        "MTrk\x00\x00\x00\x0a\x00\x90\x3c\x64\x00\xf0\x00\x00\x3e\x64";
    try std.testing.expectError(error.InvalidHeader, parse(std.testing.allocator, sysex));

    const meta = "MThd\x00\x00\x00\x06\x00\x00\x00\x01\x01\xe0" ++
        "MTrk\x00\x00\x00\x0b\x00\x90\x3c\x64\x00\xff\x01\x00\x00\x3e\x64";
    try std.testing.expectError(error.InvalidHeader, parse(std.testing.allocator, meta));
}

fn parseForAllocationTest(allocator: std.mem.Allocator, bytes: []const u8) !void {
    const result = try parse(allocator, bytes);
    result.deinit(allocator);
}

test "parse cleans up every partial allocation" {
    const notes = [_]Note{
        .{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0, .velocity = 1.0 },
        .{ .pitch = 64, .start_beat = 1.0, .duration_beat = 0.5, .velocity = 0.5 },
    };
    const bytes = try write(std.testing.allocator, &notes, 140.0);
    defer std.testing.allocator.free(bytes);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseForAllocationTest, .{bytes});
}

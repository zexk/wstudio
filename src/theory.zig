//! Scale + diatonic chord theory shared by the piano roll's scale
//! highlighting (`App.piano_scale`, set via `:scale`) and its chord-stamp
//! keys (`c` / `C`). Pure theory - no TUI or DSP dependency.

const std = @import("std");

pub const ScaleType = enum {
    // zig fmt: off
    major, minor, dorian, phrygian, lydian, mixolydian, locrian,
    major_pentatonic, minor_pentatonic, chromatic,

    /// Ascending semitone offsets from the root, within one octave.
    pub fn intervals(self: ScaleType) []const u8 {
        return switch (self) {
            .major             => &[_]u8{ 0, 2, 4, 5, 7, 9, 11 },
            .minor             => &[_]u8{ 0, 2, 3, 5, 7, 8, 10 },
            .dorian            => &[_]u8{ 0, 2, 3, 5, 7, 9, 10 },
            .phrygian          => &[_]u8{ 0, 1, 3, 5, 7, 8, 10 },
            .lydian            => &[_]u8{ 0, 2, 4, 6, 7, 9, 11 },
            .mixolydian        => &[_]u8{ 0, 2, 4, 5, 7, 9, 10 },
            .locrian           => &[_]u8{ 0, 1, 3, 5, 6, 8, 10 },
            .major_pentatonic  => &[_]u8{ 0, 2, 4, 7, 9 },
            .minor_pentatonic  => &[_]u8{ 0, 3, 5, 7, 10 },
            .chromatic         => &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 },
            // zig fmt: on
        };
    }

    pub fn label(self: ScaleType) []const u8 {
        return switch (self) {
            .major => "major",
            .minor => "minor",
            .dorian => "dorian",
            .phrygian => "phrygian",
            .lydian => "lydian",
            .mixolydian => "mixolydian",
            .locrian => "locrian",
            .major_pentatonic => "maj-pent",
            .minor_pentatonic => "min-pent",
            .chromatic => "chromatic",
        };
    }

    /// Parses the names/aliases accepted by `:scale` (case-insensitive).
    pub fn parse(s: []const u8) ?ScaleType {
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(s, "major") or eq(s, "ionian")) return .major;
        if (eq(s, "minor") or eq(s, "aeolian")) return .minor;
        if (eq(s, "dorian")) return .dorian;
        if (eq(s, "phrygian")) return .phrygian;
        if (eq(s, "lydian")) return .lydian;
        if (eq(s, "mixolydian")) return .mixolydian;
        if (eq(s, "locrian")) return .locrian;
        if (eq(s, "majpent") or eq(s, "major-pentatonic") or eq(s, "major_pentatonic")) return .major_pentatonic;
        if (eq(s, "minpent") or eq(s, "minor-pentatonic") or eq(s, "minor_pentatonic")) return .minor_pentatonic;
        if (eq(s, "chromatic")) return .chromatic;
        return null;
    }
};

const pc_names = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };

pub fn pitchClassName(pc: u4) []const u8 {
    return pc_names[pc % 12];
}

/// Whether the pitch lands on a piano black key - the accidental pitch
/// classes. Both frontends shade keyboard gutters and grid rows with this.
pub fn isBlackKey(pitch: u7) bool {
    return switch (pitch % 12) {
        1, 3, 6, 8, 10 => true,
        else => false,
    };
}

/// Parses a note letter (A-G, case-insensitive) with an optional trailing
/// `#`/`s` (sharp) or `b` (flat) - e.g. "c", "F#", "Bb". Null on anything else.
pub fn parsePitchClass(s: []const u8) ?u4 {
    if (s.len == 0 or s.len > 2) return null;
    const base: i32 = switch (std.ascii.toUpper(s[0])) {
        // zig fmt: off
        'C' => 0, 'D' => 2, 'E' => 4, 'F' => 5, 'G' => 7, 'A' => 9, 'B' => 11,
        // zig fmt: on
        else => return null,
    };
    var acc: i32 = 0;
    if (s.len > 1) {
        acc = switch (std.ascii.toLower(s[1])) {
            '#', 's' => 1,
            'b' => -1,
            else => return null,
        };
    }
    return @intCast(@mod(base + acc, 12));
}

pub const Scale = struct {
    /// Pitch class of the root, 0 = C .. 11 = B.
    root: u4 = 0,
    kind: ScaleType = .major,

    pub fn contains(self: Scale, pitch: u7) bool {
        const pc: i32 = @mod(@as(i32, pitch) - @as(i32, self.root), 12);
        for (self.kind.intervals()) |iv| {
            if (@as(i32, iv) == pc) return true;
        }
        return false;
    }

    /// Nearest pitch in this scale, for `:snap-scale`. Ties (an out-of-scale
    /// tone exactly between two scale members, e.g. D# in C major) round
    /// down, so a chromatic run collapses predictably instead of alternating
    /// direction. Always terminates: every scale has a member within 6
    /// semitones of any pitch, and the walk is clamped to 0-127.
    pub fn nearest(self: Scale, pitch: u7) u7 {
        if (self.contains(pitch)) return pitch;
        var d: i32 = 1;
        while (d <= 6) : (d += 1) {
            const down = @as(i32, pitch) - d;
            if (down >= 0 and self.contains(@intCast(down))) return @intCast(down);
            const up = @as(i32, pitch) + d;
            if (up <= 127 and self.contains(@intCast(up))) return @intCast(up);
        }
        return pitch;
    }

    pub const Chord = struct {
        pitches: [4]u7 = undefined,
        count: u3 = 0,

        /// Raise the lowest `n` chord tones by an octave: `n = 1` is first
        /// inversion (root on top), `n = 2` second, and so on. `n` is
        /// clamped to `count - 1`, since rotating every voice is just the
        /// same chord an octave up. All-or-nothing at the top of the MIDI
        /// range - a shift that would run past 127 leaves the chord as it
        /// was rather than stacking voices onto the same pitch.
        pub fn inverted(self: Chord, n: u3) Chord {
            if (self.count == 0) return self;
            var out = self;
            for (0..@min(n, self.count - 1)) |i| {
                if (@as(i32, out.pitches[i]) + 12 > 127) return self;
                out.pitches[i] += 12;
            }
            return out;
        }
    };

    /// The diatonic triad (`seventh = false`) or seventh chord stacked from
    /// `pitch` using this scale's degrees - e.g. in C major, chordAt(D,
    /// false) gives D-F-A (ii). Falls back to a plain major/major-7th shape
    /// rooted at `pitch` when it doesn't sit on the scale (a chromatic
    /// passing tone) or the scale is pentatonic/chromatic, where stacking
    /// scale-degree thirds doesn't produce an ordinary triad.
    pub fn chordAt(self: Scale, pitch: u7, seventh: bool) Chord {
        switch (self.kind) {
            .major_pentatonic, .chromatic => return fixedChord(pitch, false, seventh),
            .minor_pentatonic => return fixedChord(pitch, true, seventh),
            else => {},
        }
        const iv = self.kind.intervals();
        const n = iv.len;
        const pc: i32 = @mod(@as(i32, pitch) - @as(i32, self.root), 12);
        var idx: ?usize = null;
        for (iv, 0..) |v, i| {
            // zig fmt: off
            if (@as(i32, v) == pc) { idx = i; break; }
            // zig fmt: on
        }
        const root_idx = idx orelse return fixedChord(pitch, false, seventh);
        const base: i32 = @as(i32, pitch) - pc;
        const steps: []const usize = if (seventh) &[_]usize{ 0, 2, 4, 6 } else &[_]usize{ 0, 2, 4 };
        var out: Chord = .{};
        for (steps) |s| {
            const deg = root_idx + s;
            const oct: i32 = @intCast(deg / n);
            const note_pc = iv[deg % n];
            const note = base + @as(i32, note_pc) + 12 * oct;
            if (note > 127) continue;
            out.pitches[out.count] = @intCast(note);
            out.count += 1;
        }
        return out;
    }
};

fn fixedChord(pitch: u7, minor: bool, seventh: bool) Scale.Chord {
    const shape: []const i32 = if (minor)
        (if (seventh) &[_]i32{ 0, 3, 7, 10 } else &[_]i32{ 0, 3, 7 })
    else
        (if (seventh) &[_]i32{ 0, 4, 7, 11 } else &[_]i32{ 0, 4, 7 });
    var out: Scale.Chord = .{};
    for (shape) |iv| {
        const note = @as(i32, pitch) + iv;
        if (note > 127) continue;
        out.pitches[out.count] = @intCast(note);
        out.count += 1;
    }
    return out;
}

// ============================================================
// Tests
// ============================================================

test "Scale.contains: C major" {
    const s = Scale{ .root = 0, .kind = .major };
    try std.testing.expect(s.contains(60)); // C4
    try std.testing.expect(s.contains(62)); // D4
    try std.testing.expect(!s.contains(61)); // C#4
}

test "pitchClassName wraps the full u4 domain" {
    try std.testing.expectEqualStrings("C", pitchClassName(12));
    try std.testing.expectEqualStrings("D#", pitchClassName(15));
}

test "Scale.contains: root transposed" {
    const s = Scale{ .root = 2, .kind = .major }; // D major
    try std.testing.expect(s.contains(62)); // D
    try std.testing.expect(s.contains(64)); // E (whole step, in D major)
    try std.testing.expect(!s.contains(65)); // F natural, not in D major
}

test "chordAt: C major ii is D-F-A" {
    const s = Scale{ .root = 0, .kind = .major };
    const c = s.chordAt(62, false); // D4
    try std.testing.expectEqual(@as(u3, 3), c.count);
    try std.testing.expectEqual(@as(u7, 62), c.pitches[0]); // D
    try std.testing.expectEqual(@as(u7, 65), c.pitches[1]); // F
    try std.testing.expectEqual(@as(u7, 69), c.pitches[2]); // A
}

test "chordAt: C major V7 is G-B-D-F" {
    const s = Scale{ .root = 0, .kind = .major };
    const c = s.chordAt(67, true); // G4
    try std.testing.expectEqual(@as(u3, 4), c.count);
    try std.testing.expectEqual(@as(u7, 67), c.pitches[0]); // G
    try std.testing.expectEqual(@as(u7, 71), c.pitches[1]); // B
    try std.testing.expectEqual(@as(u7, 74), c.pitches[2]); // D5
    try std.testing.expectEqual(@as(u7, 77), c.pitches[3]); // F5
}

test "chordAt: no scale (default major) gives a plain major triad" {
    const s = Scale{ .root = 61 % 12, .kind = .major };
    const c = s.chordAt(61, false); // C#
    try std.testing.expectEqual(@as(u7, 61), c.pitches[0]);
    try std.testing.expectEqual(@as(u7, 65), c.pitches[1]);
    try std.testing.expectEqual(@as(u7, 68), c.pitches[2]);
}

test "chordAt: chromatic passing tone falls back to major shape" {
    const s = Scale{ .root = 0, .kind = .major };
    const c = s.chordAt(61, false); // C#, not in C major
    try std.testing.expectEqual(@as(u7, 61), c.pitches[0]);
    try std.testing.expectEqual(@as(u7, 65), c.pitches[1]);
    try std.testing.expectEqual(@as(u7, 68), c.pitches[2]);
}

test "chordAt: minor pentatonic uses the fixed minor shape" {
    const s = Scale{ .root = 0, .kind = .minor_pentatonic };
    const c = s.chordAt(60, true);
    try std.testing.expectEqual(@as(u3, 4), c.count);
    try std.testing.expectEqualSlices(u7, &.{ 60, 63, 67, 70 }, &c.pitches);
}

test "chordAt: voices past the MIDI ceiling are omitted" {
    const c = (Scale{ .root = 7, .kind = .major }).chordAt(127, true);
    try std.testing.expectEqual(@as(u3, 1), c.count);
    try std.testing.expectEqual(@as(u7, 127), c.pitches[0]);
}

test "Chord.inverted: raises the lowest voices, clamps a full rotation, bails at 127" {
    const s = Scale{ .root = 0, .kind = .major };
    const triad = s.chordAt(60, false); // C-E-G
    try std.testing.expectEqualSlices(u7, &.{ 72, 64, 67 }, triad.inverted(1).pitches[0..3]);
    try std.testing.expectEqualSlices(u7, &.{ 72, 76, 67 }, triad.inverted(2).pitches[0..3]);
    // A triad has only two inversions; more is the same chord an octave up,
    // so it stops at the second rather than transposing the whole shape.
    try std.testing.expectEqualSlices(u7, &.{ 72, 76, 67 }, triad.inverted(5).pitches[0..3]);

    // No room to raise the root: the chord comes back untouched, never with
    // two voices stacked on the same clamped pitch.
    const high = s.chordAt(120, false); // 120-124-127
    try std.testing.expectEqualSlices(u7, high.pitches[0..3], high.inverted(1).pitches[0..3]);
}

test "parsePitchClass: letters, sharps, flats" {
    try std.testing.expectEqual(@as(?u4, 0), parsePitchClass("c"));
    try std.testing.expectEqual(@as(?u4, 6), parsePitchClass("F#"));
    try std.testing.expectEqual(@as(?u4, 10), parsePitchClass("Bb"));
    try std.testing.expectEqual(@as(?u4, null), parsePitchClass("H"));
}

test "ScaleType.parse: names and aliases" {
    try std.testing.expectEqual(@as(?ScaleType, .major), ScaleType.parse("Major"));
    try std.testing.expectEqual(@as(?ScaleType, .minor), ScaleType.parse("aeolian"));
    try std.testing.expectEqual(@as(?ScaleType, .major_pentatonic), ScaleType.parse("major-pentatonic"));
    try std.testing.expectEqual(@as(?ScaleType, null), ScaleType.parse("bogus"));
}

test "Scale.nearest: in-scale stays put, ties round down, edges stay in range" {
    const c_major = Scale{ .root = 0, .kind = .major };
    try std.testing.expectEqual(@as(u7, 60), c_major.nearest(60)); // C
    try std.testing.expectEqual(@as(u7, 60), c_major.nearest(61)); // C# -> C
    try std.testing.expectEqual(@as(u7, 62), c_major.nearest(63)); // D# tie -> D
    try std.testing.expectEqual(@as(u7, 65), c_major.nearest(66)); // F# -> F
    // Pentatonic has 3-semitone gaps, so the walk runs further than 1.
    const c_pent = Scale{ .root = 0, .kind = .minor_pentatonic };
    try std.testing.expectEqual(@as(u7, 63), c_pent.nearest(64)); // E -> Eb
    // Near the MIDI edges the walk still only lands on real pitches.
    try std.testing.expectEqual(@as(u7, 0), c_major.nearest(1));
    try std.testing.expectEqual(@as(u7, 125), c_major.nearest(126));
}

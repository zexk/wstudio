//! Scale + diatonic chord theory shared by the piano roll's scale
//! highlighting (project scale, set via `:scale`) and its chord-stamp
//! keys (`c` / `C`). Pure theory - no TUI or DSP dependency.

const std = @import("std");

pub const ScaleType = enum {
    // zig fmt: off
    major, minor, dorian, phrygian, lydian, mixolydian, locrian,
    major_pentatonic, minor_pentatonic, blues, major_blues,
    harmonic_minor, melodic_minor, lydian_dominant, phrygian_dominant, altered,
    bebop_major, bebop_dominant, bebop_minor, bebop_dorian,
    whole_tone, diminished_whole_half, diminished_half_whole,
    double_harmonic, hungarian_minor, ukrainian_dorian,
    neapolitan_major, neapolitan_minor, persian, enigmatic,
    hirajoshi, in_sen, iwato, prometheus, chromatic,

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
            .blues             => &[_]u8{ 0, 3, 5, 6, 7, 10 },
            .major_blues       => &[_]u8{ 0, 2, 3, 4, 7, 9 },
            .harmonic_minor    => &[_]u8{ 0, 2, 3, 5, 7, 8, 11 },
            .melodic_minor     => &[_]u8{ 0, 2, 3, 5, 7, 9, 11 },
            .lydian_dominant   => &[_]u8{ 0, 2, 4, 6, 7, 9, 10 },
            .phrygian_dominant => &[_]u8{ 0, 1, 4, 5, 7, 8, 10 },
            .altered           => &[_]u8{ 0, 1, 3, 4, 6, 8, 10 },
            .bebop_major       => &[_]u8{ 0, 2, 4, 5, 7, 8, 9, 11 },
            .bebop_dominant    => &[_]u8{ 0, 2, 4, 5, 7, 9, 10, 11 },
            .bebop_minor       => &[_]u8{ 0, 2, 3, 4, 5, 7, 8, 10 },
            .bebop_dorian      => &[_]u8{ 0, 2, 3, 4, 5, 7, 9, 10 },
            .whole_tone        => &[_]u8{ 0, 2, 4, 6, 8, 10 },
            .diminished_whole_half => &[_]u8{ 0, 2, 3, 5, 6, 8, 9, 11 },
            .diminished_half_whole => &[_]u8{ 0, 1, 3, 4, 6, 7, 9, 10 },
            .double_harmonic   => &[_]u8{ 0, 1, 4, 5, 7, 8, 11 },
            .hungarian_minor   => &[_]u8{ 0, 2, 3, 6, 7, 8, 11 },
            .ukrainian_dorian  => &[_]u8{ 0, 2, 3, 6, 7, 9, 10 },
            .neapolitan_major  => &[_]u8{ 0, 1, 3, 5, 7, 9, 11 },
            .neapolitan_minor  => &[_]u8{ 0, 1, 3, 5, 7, 8, 11 },
            .persian           => &[_]u8{ 0, 1, 4, 5, 6, 8, 11 },
            .enigmatic         => &[_]u8{ 0, 1, 4, 6, 8, 10, 11 },
            .hirajoshi         => &[_]u8{ 0, 2, 3, 7, 8 },
            .in_sen            => &[_]u8{ 0, 1, 5, 7, 10 },
            .iwato             => &[_]u8{ 0, 1, 5, 6, 10 },
            .prometheus        => &[_]u8{ 0, 2, 4, 6, 9, 10 },
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
            .blues => "blues",
            .major_blues => "major-blues",
            .harmonic_minor => "harmonic-minor",
            .melodic_minor => "melodic-minor",
            .lydian_dominant => "lydian-dominant",
            .phrygian_dominant => "phrygian-dominant",
            .altered => "altered",
            .bebop_major => "bebop-major",
            .bebop_dominant => "bebop-dominant",
            .bebop_minor => "bebop-minor",
            .bebop_dorian => "bebop-dorian",
            .whole_tone => "whole-tone",
            .diminished_whole_half => "diminished-whole-half",
            .diminished_half_whole => "diminished-half-whole",
            .double_harmonic => "double-harmonic",
            .hungarian_minor => "hungarian-minor",
            .ukrainian_dorian => "ukrainian-dorian",
            .neapolitan_major => "neapolitan-major",
            .neapolitan_minor => "neapolitan-minor",
            .persian => "persian",
            .enigmatic => "enigmatic",
            .hirajoshi => "hirajoshi",
            .in_sen => "in-sen",
            .iwato => "iwato",
            .prometheus => "prometheus",
            .chromatic => "chromatic",
        };
    }

    /// Parses the names/aliases accepted by `:scale` (case-insensitive).
    pub fn parse(s: []const u8) ?ScaleType {
        const eq = std.ascii.eqlIgnoreCase;
        for (std.meta.tags(ScaleType)) |kind| {
            if (eq(s, @tagName(kind)) or eq(s, kind.label())) return kind;
        }
        if (eq(s, "ionian")) return .major;
        if (eq(s, "aeolian")) return .minor;
        if (eq(s, "majpent") or eq(s, "major-pentatonic") or eq(s, "major_pentatonic")) return .major_pentatonic;
        if (eq(s, "minpent") or eq(s, "minor-pentatonic") or eq(s, "minor_pentatonic")) return .minor_pentatonic;
        if (eq(s, "super-locrian")) return .altered;
        if (eq(s, "byzantine") or eq(s, "arabic")) return .double_harmonic;
        return null;
    }

    /// Major-family vs minor-family mode, for `fixedChord`'s 3rd/7th flavor
    /// when a chord quality isn't diatonically derived (sus/add9/dim/aug/6th).
    pub fn isMinorish(self: ScaleType) bool {
        return switch (self) {
            .minor, .dorian, .phrygian, .locrian, .minor_pentatonic, .blues, .harmonic_minor, .melodic_minor, .bebop_minor, .bebop_dorian, .hungarian_minor, .ukrainian_dorian, .neapolitan_minor, .hirajoshi, .in_sen, .iwato => true,
            else => false,
        };
    }
};

/// The chord shape `c`/`C`/`o`/`O` stamp in the piano roll. `triad` through
/// `thirteenth` stack diatonically (in scale-degree thirds) when the root
/// sits on the active `:scale`; the rest are quality overrides that always
/// use a fixed, scale-independent interval shape (a sus chord replaces the
/// 3rd outright, so "diatonic sus2" isn't a meaningful thing to derive).
pub const ChordQuality = enum {
    triad,
    sixth,
    seventh,
    ninth,
    eleventh,
    thirteenth,
    sus2,
    sus4,
    add9,
    dim,
    aug,

    pub const count = @typeInfo(ChordQuality).@"enum".fields.len;

    pub fn cycle(self: ChordQuality, delta: i32) ChordQuality {
        const cur: i32 = @intFromEnum(self);
        return @enumFromInt(@mod(cur + delta, @as(i32, count)));
    }

    pub fn label(self: ChordQuality) []const u8 {
        return switch (self) {
            .triad => "triad",
            .sixth => "6th",
            .seventh => "7th",
            .ninth => "9th",
            .eleventh => "11th",
            .thirteenth => "13th",
            .sus2 => "sus2",
            .sus4 => "sus4",
            .add9 => "add9",
            .dim => "dim",
            .aug => "aug",
        };
    }

    /// Diatonic third-stacking only makes sense for the tertian qualities -
    /// sus/add9/dim/aug/6th are quality overrides, always a fixed shape.
    fn isTertian(self: ChordQuality) bool {
        return switch (self) {
            .triad, .seventh, .ninth, .eleventh, .thirteenth => true,
            .sixth, .sus2, .sus4, .add9, .dim, .aug => false,
        };
    }
};

/// A chord voicing spread applied in place - `r`/`R` cycle it in the piano
/// roll, re-stamping the same chord wider or tighter without changing its
/// root or quality.
pub const Voicing = enum {
    closed,
    drop2,
    open,

    pub const count = @typeInfo(Voicing).@"enum".fields.len;

    pub fn cycle(self: Voicing, delta: i32) Voicing {
        const cur: i32 = @intFromEnum(self);
        return @enumFromInt(@mod(cur + delta, @as(i32, count)));
    }

    pub fn label(self: Voicing) []const u8 {
        return switch (self) {
            .closed => "closed",
            .drop2 => "drop2",
            .open => "open",
        };
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
        pitches: [7]u7 = undefined,
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

        /// Spread the chord wider (`drop2`: the 2nd-from-top voice drops an
        /// octave, `open`: every other voice above the root pushed up an
        /// octave) or back to `closed` (as stacked). All-or-nothing at the
        /// MIDI range edges, like `inverted`.
        pub fn voiced(self: Chord, kind: Voicing) Chord {
            if (self.count < 2) return self;
            var out = self;
            switch (kind) {
                .closed => {},
                .drop2 => {
                    const i = self.count - 2;
                    if (@as(i32, out.pitches[i]) - 12 < 0) return self;
                    out.pitches[i] -= 12;
                },
                .open => {
                    var i: usize = 1;
                    while (i < out.count) : (i += 2) {
                        if (@as(i32, out.pitches[i]) + 12 > 127) return self;
                        out.pitches[i] += 12;
                    }
                },
            }
            return out;
        }
    };

    /// The chord of `quality` stacked from `pitch` using this scale's
    /// degrees - e.g. in C major, chordAt(D, .triad) gives D-F-A (ii).
    /// Falls back to a fixed shape rooted at `pitch` (major or minor by the
    /// scale's mode, see `ScaleType.isMinorish`) when `quality` isn't
    /// tertian (sus/add9/dim/aug/6th - see `ChordQuality.isTertian`),
    /// `pitch` doesn't sit on the scale (a chromatic passing tone), or the
    /// scale is pentatonic/chromatic, where stacking scale-degree thirds
    /// doesn't produce an ordinary chord.
    pub fn chordAt(self: Scale, pitch: u7, quality: ChordQuality) Chord {
        const minor = self.kind.isMinorish();
        if (!quality.isTertian()) return fixedChord(pitch, minor, quality);
        const iv = self.kind.intervals();
        if (iv.len != 7) return fixedChord(pitch, minor, quality);
        const n = iv.len;
        const pc: i32 = @mod(@as(i32, pitch) - @as(i32, self.root), 12);
        var idx: ?usize = null;
        for (iv, 0..) |v, i| {
            // zig fmt: off
            if (@as(i32, v) == pc) { idx = i; break; }
            // zig fmt: on
        }
        const root_idx = idx orelse return fixedChord(pitch, minor, quality);
        const base: i32 = @as(i32, pitch) - pc;
        const steps: []const usize = switch (quality) {
            .triad => &[_]usize{ 0, 2, 4 },
            .seventh => &[_]usize{ 0, 2, 4, 6 },
            .ninth => &[_]usize{ 0, 2, 4, 6, 8 },
            .eleventh => &[_]usize{ 0, 2, 4, 6, 8, 10 },
            .thirteenth => &[_]usize{ 0, 2, 4, 6, 8, 10, 12 },
            else => unreachable, // isTertian() guards this
        };
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

/// Fixed, scale-independent interval shape for `quality` rooted at `pitch`.
/// `minor` picks the 3rd/7th/9th/13th flavor for the qualities that have
/// one; sus2/sus4/dim/aug have no diatonic 3rd and ignore it.
fn fixedChord(pitch: u7, minor: bool, quality: ChordQuality) Scale.Chord {
    const shape: []const i32 = switch (quality) {
        .triad => if (minor) &[_]i32{ 0, 3, 7 } else &[_]i32{ 0, 4, 7 },
        .sixth => if (minor) &[_]i32{ 0, 3, 7, 9 } else &[_]i32{ 0, 4, 7, 9 },
        .seventh => if (minor) &[_]i32{ 0, 3, 7, 10 } else &[_]i32{ 0, 4, 7, 11 },
        .ninth => if (minor) &[_]i32{ 0, 3, 7, 10, 14 } else &[_]i32{ 0, 4, 7, 11, 14 },
        .eleventh => if (minor) &[_]i32{ 0, 3, 7, 10, 14, 17 } else &[_]i32{ 0, 4, 7, 11, 14, 17 },
        .thirteenth => if (minor) &[_]i32{ 0, 3, 7, 10, 14, 17, 21 } else &[_]i32{ 0, 4, 7, 11, 14, 17, 21 },
        .sus2 => &[_]i32{ 0, 2, 7 },
        .sus4 => &[_]i32{ 0, 5, 7 },
        .add9 => if (minor) &[_]i32{ 0, 3, 7, 14 } else &[_]i32{ 0, 4, 7, 14 },
        .dim => &[_]i32{ 0, 3, 6 },
        .aug => &[_]i32{ 0, 4, 8 },
    };
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
    const c = s.chordAt(62, .triad); // D4
    try std.testing.expectEqual(@as(u3, 3), c.count);
    try std.testing.expectEqual(@as(u7, 62), c.pitches[0]); // D
    try std.testing.expectEqual(@as(u7, 65), c.pitches[1]); // F
    try std.testing.expectEqual(@as(u7, 69), c.pitches[2]); // A
}

test "chordAt: C major V7 is G-B-D-F" {
    const s = Scale{ .root = 0, .kind = .major };
    const c = s.chordAt(67, .seventh); // G4
    try std.testing.expectEqual(@as(u3, 4), c.count);
    try std.testing.expectEqual(@as(u7, 67), c.pitches[0]); // G
    try std.testing.expectEqual(@as(u7, 71), c.pitches[1]); // B
    try std.testing.expectEqual(@as(u7, 74), c.pitches[2]); // D5
    try std.testing.expectEqual(@as(u7, 77), c.pitches[3]); // F5
}

test "chordAt: C major V9 stacks a 5th third on top of the V7" {
    const s = Scale{ .root = 0, .kind = .major };
    const c = s.chordAt(67, .ninth); // G4
    try std.testing.expectEqual(@as(u3, 5), c.count);
    try std.testing.expectEqualSlices(u7, &.{ 67, 71, 74, 77, 81 }, c.pitches[0..5]);
}

test "chordAt: no scale (default major) gives a plain major triad" {
    const s = Scale{ .root = 61 % 12, .kind = .major };
    const c = s.chordAt(61, .triad); // C#
    try std.testing.expectEqual(@as(u7, 61), c.pitches[0]);
    try std.testing.expectEqual(@as(u7, 65), c.pitches[1]);
    try std.testing.expectEqual(@as(u7, 68), c.pitches[2]);
}

test "chordAt: chromatic passing tone falls back to major shape" {
    const s = Scale{ .root = 0, .kind = .major };
    const c = s.chordAt(61, .triad); // C#, not in C major
    try std.testing.expectEqual(@as(u7, 61), c.pitches[0]);
    try std.testing.expectEqual(@as(u7, 65), c.pitches[1]);
    try std.testing.expectEqual(@as(u7, 68), c.pitches[2]);
}

test "chordAt: minor pentatonic uses the fixed minor shape" {
    const s = Scale{ .root = 0, .kind = .minor_pentatonic };
    const c = s.chordAt(60, .seventh);
    try std.testing.expectEqual(@as(u3, 4), c.count);
    try std.testing.expectEqualSlices(u7, &.{ 60, 63, 67, 70 }, c.pitches[0..4]);
}

test "chordAt: voices past the MIDI ceiling are omitted" {
    const c = (Scale{ .root = 7, .kind = .major }).chordAt(127, .seventh);
    try std.testing.expectEqual(@as(u3, 1), c.count);
    try std.testing.expectEqual(@as(u7, 127), c.pitches[0]);
}

test "chordAt: sus2/sus4/dim/aug are fixed shapes regardless of scale" {
    const s = Scale{ .root = 0, .kind = .major };
    try std.testing.expectEqualSlices(u7, &.{ 60, 62, 67 }, s.chordAt(60, .sus2).pitches[0..3]);
    try std.testing.expectEqualSlices(u7, &.{ 60, 65, 67 }, s.chordAt(60, .sus4).pitches[0..3]);
    try std.testing.expectEqualSlices(u7, &.{ 60, 63, 66 }, s.chordAt(60, .dim).pitches[0..3]);
    try std.testing.expectEqualSlices(u7, &.{ 60, 64, 68 }, s.chordAt(60, .aug).pitches[0..3]);
}

test "chordAt: sixth/add9 flavor by the scale's mode" {
    try std.testing.expectEqualSlices(u7, &.{ 60, 64, 67, 69 }, (Scale{ .root = 0, .kind = .major }).chordAt(60, .sixth).pitches[0..4]);
    try std.testing.expectEqualSlices(u7, &.{ 60, 63, 67, 69 }, (Scale{ .root = 0, .kind = .minor }).chordAt(60, .sixth).pitches[0..4]);
}

test "Chord.inverted: raises the lowest voices, clamps a full rotation, bails at 127" {
    const s = Scale{ .root = 0, .kind = .major };
    const triad = s.chordAt(60, .triad); // C-E-G
    try std.testing.expectEqualSlices(u7, &.{ 72, 64, 67 }, triad.inverted(1).pitches[0..3]);
    try std.testing.expectEqualSlices(u7, &.{ 72, 76, 67 }, triad.inverted(2).pitches[0..3]);
    // A triad has only two inversions; more is the same chord an octave up,
    // so it stops at the second rather than transposing the whole shape.
    try std.testing.expectEqualSlices(u7, &.{ 72, 76, 67 }, triad.inverted(5).pitches[0..3]);

    // No room to raise the root: the chord comes back untouched, never with
    // two voices stacked on the same clamped pitch.
    const high = s.chordAt(120, .triad); // 120-124-127
    try std.testing.expectEqualSlices(u7, high.pitches[0..3], high.inverted(1).pitches[0..3]);
}

test "Chord.voiced: drop2 drops the 2nd-from-top voice, open spreads alternate voices" {
    const s = Scale{ .root = 0, .kind = .major };
    const seventh = s.chordAt(60, .seventh); // C-E-G-B (60,64,67,71)
    try std.testing.expectEqualSlices(u7, &.{ 60, 64, 55, 71 }, seventh.voiced(.drop2).pitches[0..4]);
    try std.testing.expectEqualSlices(u7, &.{ 60, 76, 67, 83 }, seventh.voiced(.open).pitches[0..4]);
    try std.testing.expectEqualSlices(u7, seventh.pitches[0..4], seventh.voiced(.closed).pitches[0..4]);

    // No room to voice further: comes back untouched rather than clamping.
    const high = s.chordAt(120, .triad); // 120-124-127
    try std.testing.expectEqualSlices(u7, high.pitches[0..3], high.voiced(.open).pitches[0..3]);
}

test "ChordQuality.cycle and Voicing.cycle wrap around" {
    try std.testing.expectEqual(ChordQuality.sixth, ChordQuality.triad.cycle(1));
    try std.testing.expectEqual(ChordQuality.aug, ChordQuality.triad.cycle(-1));
    try std.testing.expectEqual(Voicing.closed, Voicing.open.cycle(1));
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
    try std.testing.expectEqual(@as(?ScaleType, .bebop_dominant), ScaleType.parse("bebop-dominant"));
    try std.testing.expectEqual(@as(?ScaleType, .whole_tone), ScaleType.parse("whole_tone"));
    try std.testing.expectEqual(@as(?ScaleType, .double_harmonic), ScaleType.parse("Byzantine"));
    try std.testing.expect((Scale{ .root = 0, .kind = .bebop_dominant }).contains(70));
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

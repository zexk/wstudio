//! Microtonal tuning: a per-pitch-class cents offset applied on top of
//! 12-tone equal temperament, so playback can sit in a temperament other
//! than the one `midi.noteToFreq` hardcodes.
//!
//! This is retuning, not scale-snapping. `theory.zig`'s `Scale` decides
//! which of the twelve keys a composition uses; a `Tuning` decides what
//! frequency each of those keys actually sounds at. They compose: a piece
//! in D dorian can be played in quarter-comma meantone.
//!
//! Twelve offsets rather than a full Scala scale file. Every historical
//! temperament (just intonation, Pythagorean, meantone, the Werckmeister
//! and Kirnberger circulating tunings) is exactly a twelve-key retuning, so
//! the table covers them without dragging in scale cardinality and keyboard
//! mapping - a 19-EDO scale needs a different note-to-key mapping, which is
//! a separate feature, not a bigger array.

const std = @import("std");

/// Cents offset per pitch class, indexed relative to `root`. `root` names
/// the pitch class the temperament is built from (its offsets are measured
/// from there), not a reference pitch - A440 stays the anchor either way,
/// so switching root re-colours the intervals without transposing anything.
pub const Tuning = struct {
    /// Offsets in cents from 12-TET, `cents[0]` being the root's own.
    /// 100 cents is one equal-tempered semitone; the useful range is well
    /// inside ±50, but nothing here clamps taste.
    cents: [12]f32 = @splat(0),
    /// Pitch class (0 = C) the offsets are measured from.
    root: u4 = 0,

    /// Offset in cents for a MIDI note. Equal temperament returns 0 for
    /// every note, which is what makes `.equal` free at the call site.
    pub fn offsetCents(self: Tuning, note: u7) f32 {
        const pc = @as(u4, @intCast(note % 12));
        // Wrap into the table's own frame: index 0 is the root, not C.
        const idx = (@as(u8, pc) + 12 - @as(u8, self.root)) % 12;
        return self.cents[idx];
    }

    /// Frequency multiplier for a note - `2^(cents/1200)`. Pitch paths that
    /// work in a rate or a log2 domain (the sampler's playback rate, the
    /// synth's glide) want this rather than an absolute frequency.
    pub fn ratio(self: Tuning, note: u7) f32 {
        const c = self.offsetCents(note);
        if (c == 0) return 1.0;
        return std.math.pow(f32, 2.0, c / 1200.0);
    }

    /// True when this tuning changes nothing, so callers can skip the whole
    /// retuning path on the audio thread - the overwhelmingly common case.
    pub fn isEqual(self: Tuning) bool {
        for (self.cents) |c| {
            if (c != 0) return false;
        }
        return true;
    }
};

/// The named temperaments offered in the UI. Each is a twelve-key offset
/// table from 12-TET, so `.equal` is all zeros by construction.
pub const Preset = enum {
    equal,
    just_major,
    pythagorean,
    meantone_quarter,
    werckmeister3,
    kirnberger3,

    pub fn label(self: Preset) []const u8 {
        return switch (self) {
            .equal => "equal (12-TET)",
            .just_major => "just intonation (major)",
            .pythagorean => "pythagorean",
            .meantone_quarter => "quarter-comma meantone",
            .werckmeister3 => "werckmeister III",
            .kirnberger3 => "kirnberger III",
        };
    }

    pub fn parse(s: []const u8) ?Preset {
        inline for (@typeInfo(Preset).@"enum".fields) |f| {
            if (std.ascii.eqlIgnoreCase(s, f.name)) return @field(Preset, f.name);
        }
        return null;
    }

    /// Cents from 12-TET for each of the twelve keys, root first.
    ///
    /// The numbers are the standard published ones, rounded to 0.1 cent -
    /// derived rather than measured, so they are stated here instead of
    /// being recomputed from ratios at startup for the four tunings whose
    /// definitions are irrational anyway.
    pub fn table(self: Preset) [12]f32 {
        // zig fmt: off
        return switch (self) {
            .equal => @splat(0),
            // 5-limit just major scale: pure thirds (5/4) and fifths (3/2).
            .just_major => .{ 0, 11.7, 3.9, 15.6, -13.7, -2.0, -9.8, 2.0, 13.7, -15.9, 17.6, -11.7 },
            // A chain of pure 3/2 fifths; the wolf lands between G# and Eb.
            .pythagorean => .{ 0, 13.7, 3.9, -5.9, 7.8, -2.0, 11.7, 2.0, 15.6, 5.9, -3.9, 9.8 },
            // Fifths narrowed by a quarter syntonic comma, buying pure
            // major thirds - the Renaissance/early-baroque default.
            .meantone_quarter => .{ 0, -24.0, -6.8, 10.3, -13.7, 3.4, -20.5, -3.4, -27.4, -10.3, 6.8, -17.1 },
            // Circulating: every key playable, each with its own colour.
            .werckmeister3 => .{ 0, 9.8, 3.9, 5.9, -2.0, 7.8, 11.7, 2.0, 7.8, 0, 3.9, 3.9 },
            .kirnberger3 => .{ 0, 10.3, 6.8, 6.8, 0.5, 8.3, 12.2, 3.4, 8.3, 3.4, 5.4, 1.0 },
        };
        // zig fmt: on
    }

    pub fn tuning(self: Preset, root: u4) Tuning {
        return .{ .cents = self.table(), .root = root };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "equal temperament changes nothing and is detectable as such" {
    const t = Preset.equal.tuning(0);
    try testing.expect(t.isEqual());
    for (0..128) |n| {
        try testing.expectApproxEqAbs(@as(f32, 0), t.offsetCents(@intCast(n)), 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 1.0), t.ratio(@intCast(n)), 1e-6);
    }
}

test "offsets repeat every octave and follow the root" {
    const t = Preset.just_major.tuning(0);
    try testing.expect(!t.isEqual());

    // C in every octave gets the root's offset; the major third is the
    // pure one just intonation is chosen for (-13.7 cents from 12-TET).
    try testing.expectApproxEqAbs(@as(f32, 0), t.offsetCents(60), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), t.offsetCents(72), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -13.7), t.offsetCents(64), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -13.7), t.offsetCents(52), 1e-4);

    // Rooting on D moves the whole pattern with it rather than transposing
    // pitches: D now takes the root offset and F# the pure third.
    const d = Preset.just_major.tuning(2);
    try testing.expectApproxEqAbs(@as(f32, 0), d.offsetCents(62), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -13.7), d.offsetCents(66), 1e-4);
}

test "ratio converts cents to a frequency multiplier" {
    var t: Tuning = .{};
    t.cents[0] = 1200.0; // a whole octave up, as an offset
    try testing.expectApproxEqAbs(@as(f32, 2.0), t.ratio(60), 1e-4);
    t.cents[0] = -1200.0;
    try testing.expectApproxEqAbs(@as(f32, 0.5), t.ratio(60), 1e-4);
    t.cents[0] = 100.0; // one equal-tempered semitone
    try testing.expectApproxEqAbs(@as(f32, 1.059463), t.ratio(60), 1e-5);
}

test "every preset is a twelve-key table and only equal is a no-op" {
    for (std.meta.tags(Preset)) |p| {
        const t = p.tuning(0);
        try testing.expectEqual(@as(f32, 0), t.cents[0]); // root is the reference
        try testing.expectEqual(p == .equal, t.isEqual());
        // A temperament that drifted past a semitone would be a typo, not a
        // tuning - every published table here sits well inside that.
        for (t.cents) |c| try testing.expect(@abs(c) < 50.0);
        try testing.expect(p.label().len > 0);
        try testing.expectEqual(p, Preset.parse(@tagName(p)).?);
    }
    try testing.expect(Preset.parse("not-a-tuning") == null);
}

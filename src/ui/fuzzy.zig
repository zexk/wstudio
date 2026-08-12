//! Minimal fuzzy matcher for `/` search - case-insensitive subsequence
//! match (the same baseline rule fzf/vim fuzzy-finder plugins use): every
//! character of `pattern` must appear in `text`, in order, not necessarily
//! contiguous. App.searchTracks/searchBrowser just want "does this candidate
//! match," walking the list for the next one that does; the pickers, which
//! show every match at once, order them by `score`.

const std = @import("std");

pub fn matches(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return true;
    var pi: usize = 0;
    for (text) |c| {
        if (pi >= pattern.len) break;
        if (std.ascii.toLower(c) == std.ascii.toLower(pattern[pi])) pi += 1;
    }
    return pi == pattern.len;
}

fn isWordBreak(c: u8) bool {
    return c == ' ' or c == '_' or c == '-' or c == '.' or c == '/' or c == ':';
}

/// How well `text` matches `pattern`, higher is better, null when it does not
/// match at all. For ordering a list of candidates the user can see all of at
/// once - `matches` alone leaves "sub" ranking `Sample Bus` level with
/// `Subtractive`, so the list order decides, and the list order is whatever
/// the table happened to be written in.
///
/// Scores the same greedy left-to-right walk `matches` and `matchPositions`
/// do, so the highlight always sits on the run that was scored. A greedy walk
/// can pick a worse alignment than an optimal one would (fzf runs a full
/// dynamic program for this); it costs the odd near-tie, not a wrong answer.
pub fn score(pattern: []const u8, text: []const u8) ?i32 {
    if (pattern.len == 0) return 0;
    var total: i32 = 0;
    var pi: usize = 0;
    var last_match: ?usize = null;
    for (text, 0..) |c, i| {
        if (pi >= pattern.len) break;
        if (std.ascii.toLower(c) != std.ascii.toLower(pattern[pi])) continue;
        // A run the user typed as one word beats the same letters scattered,
        // and outweighs the word-start bonus below: typing "sub" wants
        // `Subtractive` ahead of `Sample Utility Bus`.
        if (last_match) |prev| {
            if (prev + 1 == i) total += 12;
        }
        // Initials count: "sb" should find `Sample Bus` ahead of `Subtle`.
        if (i == 0 or isWordBreak(text[i - 1])) total += 10;
        // Matching near the front beats matching deep inside a long name.
        if (pi == 0) total -= @intCast(@min(i, 20));
        last_match = i;
        pi += 1;
    }
    if (pi < pattern.len) return null;
    // Tie-break on how much of the candidate the pattern actually covers.
    total -= @intCast(@min(text.len, 40) / 4);
    return total;
}

/// Marks which bytes of `text` the same greedy subsequence walk `matches`
/// does would consume - for rendering a match highlight, not for deciding
/// whether it matched at all. `out` must be at least `text.len` long; bytes
/// past a short pattern (or past a non-match) are left false.
pub fn matchPositions(pattern: []const u8, text: []const u8, out: []bool) void {
    @memset(out[0..text.len], false);
    var pi: usize = 0;
    for (text, 0..) |c, i| {
        if (pi >= pattern.len) break;
        if (std.ascii.toLower(c) == std.ascii.toLower(pattern[pi])) {
            out[i] = true;
            pi += 1;
        }
    }
}

test "empty pattern matches anything" {
    try std.testing.expect(matches("", "whatever"));
    try std.testing.expect(matches("", ""));
}

test "subsequence match, case-insensitive, gaps allowed" {
    try std.testing.expect(matches("snr", "Synth Rack"));
    try std.testing.expect(matches("SNR", "synth rack"));
    try std.testing.expect(matches("synth", "Synth Rack"));
    try std.testing.expect(matches("rack", "Synth Rack"));
}

test "characters out of order don't match" {
    try std.testing.expect(!matches("rns", "Synth Rack"));
}

test "pattern longer than text never matches" {
    try std.testing.expect(!matches("synthesizer", "synth"));
}

test "unmatched character anywhere breaks the match" {
    try std.testing.expect(!matches("synz", "Synth Rack"));
}

test "matchPositions marks the same greedy subsequence matches() found" {
    var out: [10]bool = undefined;
    matchPositions("snr", "Synth Rack", &out);
    // S  y  n  t  h     R  a  c  k
    // x     x           x
    try std.testing.expectEqualSlices(bool, &.{ true, false, true, false, false, false, true, false, false, false }, &out);
}

test "score answers null on exactly the inputs matches() rejects" {
    const cases = [_][2][]const u8{
        .{ "snr", "Synth Rack" },
        .{ "rns", "Synth Rack" },
        .{ "synthesizer", "synth" },
        .{ "", "anything" },
    };
    for (cases) |c| {
        try std.testing.expectEqual(matches(c[0], c[1]), score(c[0], c[1]) != null);
    }
}

test "score prefers a contiguous prefix, then initials, then scattered" {
    const prefix = score("sub", "Subtractive").?;
    const initials = score("sub", "Sample Utility Bus").?;
    const scattered = score("sub", "Sidechain Ducker Bypass").?;
    try std.testing.expect(prefix > initials);
    try std.testing.expect(initials > scattered);
}

test "score prefers the shorter of two equally good matches" {
    try std.testing.expect(score("osc", "Oscillator").? > score("osc", "Oscillator Bank Module").?);
}

test "score penalises a match that starts deep inside the name" {
    try std.testing.expect(score("rack", "Rack Extension").? > score("rack", "Percussion Rack").?);
}

test "matchPositions on empty pattern marks nothing" {
    var out: [4]bool = undefined;
    matchPositions("", "abcd", &out);
    try std.testing.expectEqualSlices(bool, &.{ false, false, false, false }, &out);
}

//! Minimal fuzzy matcher for `/` search — case-insensitive subsequence
//! match (the same baseline rule fzf/vim fuzzy-finder plugins use): every
//! character of `pattern` must appear in `text`, in order, not necessarily
//! contiguous. No ranking/scoring — App.searchTracks/searchBrowser just want
//! "does this candidate match," walking the list for the next one that does.

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

/// Marks which bytes of `text` the same greedy subsequence walk `matches`
/// does would consume — for rendering a match highlight, not for deciding
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

test "matchPositions on empty pattern marks nothing" {
    var out: [4]bool = undefined;
    matchPositions("", "abcd", &out);
    try std.testing.expectEqualSlices(bool, &.{ false, false, false, false }, &out);
}

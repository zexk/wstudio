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

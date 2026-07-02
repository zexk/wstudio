//! Undo/redo history for content edits (UI thread only).
//!
//! Snapshot-based: before a mutating edit, the App captures the whole state
//! of the domain being touched — one track's melodic pattern, one drum
//! machine's pattern bank, or one arrangement lane — and pushes it here.
//! Undo swaps the captured state with the live one (the displaced state
//! moves to the redo stack), so undo/redo walk the same entries in both
//! directions. Track-level operations (add/delete/instrument swap) and
//! continuous param nudges (synth editor, swing, EQ, mixer) are
//! deliberately out of scope: the stack covers the note/pattern/clip data
//! an artist can't reconstruct by ear.

const std = @import("std");
const ws = @import("wstudio");

const Note = ws.dsp.pattern.Note;
const DrumMachine = ws.dsp.DrumMachine;
const Clip = ws.Clip;

/// Entries kept on the undo side; the oldest fall off beyond this.
pub const max_entries: usize = 64;

/// One track's live melodic pattern. When the piano roll was linked to an
/// arrangement clip at capture time, `clip_start_bar` remembers it so the
/// restore re-links and writes the notes back into that clip too.
pub const MelodicState = struct {
    track: u16,
    length_beats: f64,
    notes: []Note, // owned
    clip_start_bar: ?u32 = null,

    pub fn deinit(self: *MelodicState, allocator: std.mem.Allocator) void {
        allocator.free(self.notes);
    }
};

/// One drum machine's whole pattern bank, active slot read from the live
/// atomics. Plain value — no allocation. Swing is a param, not captured.
pub const DrumState = struct {
    track: u16,
    variants: [DrumMachine.max_variants]DrumMachine.Variant,
    variant_count: u8,
    variant: u8,
};

/// One arrangement lane's clips (deep copies; melodic notes owned).
pub const LaneState = struct {
    track: u16,
    clips: []Clip, // owned, including each melodic clip's notes

    pub fn deinit(self: *LaneState, allocator: std.mem.Allocator) void {
        for (self.clips) |*c| c.deinit(allocator);
        allocator.free(self.clips);
    }
};

pub const Entry = union(enum) {
    melodic: MelodicState,
    drum: DrumState,
    lane: LaneState,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .melodic => |*m| m.deinit(allocator),
            .drum => {},
            .lane => |*l| l.deinit(allocator),
        }
    }

    pub fn label(self: *const Entry) []const u8 {
        return switch (self.*) {
            .melodic => "pattern",
            .drum => "drum",
            .lane => "clip",
        };
    }
};

pub const History = struct {
    undo_stack: std.ArrayListUnmanaged(Entry) = .empty,
    redo_stack: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn deinit(self: *History, allocator: std.mem.Allocator) void {
        for (self.undo_stack.items) |*e| e.deinit(allocator);
        for (self.redo_stack.items) |*e| e.deinit(allocator);
        self.undo_stack.deinit(allocator);
        self.redo_stack.deinit(allocator);
    }

    /// Record a pre-edit state. A fresh edit invalidates the redo branch.
    /// Takes ownership of `entry` (freed on overflow or append failure).
    pub fn push(self: *History, allocator: std.mem.Allocator, entry: Entry) void {
        for (self.redo_stack.items) |*e| e.deinit(allocator);
        self.redo_stack.clearRetainingCapacity();
        if (self.undo_stack.items.len >= max_entries) {
            var oldest = self.undo_stack.orderedRemove(0);
            oldest.deinit(allocator);
        }
        self.undo_stack.append(allocator, entry) catch {
            var owned = entry;
            owned.deinit(allocator);
        };
    }

    pub fn popUndo(self: *History) ?Entry {
        return self.undo_stack.pop();
    }

    pub fn popRedo(self: *History) ?Entry {
        return self.redo_stack.pop();
    }

    /// Park the state an undo displaced, so redo can bring it back.
    pub fn parkRedo(self: *History, allocator: std.mem.Allocator, entry: Entry) void {
        self.redo_stack.append(allocator, entry) catch {
            var owned = entry;
            owned.deinit(allocator);
        };
    }

    /// Park the state a redo displaced, back onto the undo side. Unlike
    /// `push`, this must not clear the redo branch being walked.
    pub fn parkUndo(self: *History, allocator: std.mem.Allocator, entry: Entry) void {
        self.undo_stack.append(allocator, entry) catch {
            var owned = entry;
            owned.deinit(allocator);
        };
    }
};

// ---------------------------------------------------------------------------
// Tests

fn melodicEntry(allocator: std.mem.Allocator, track: u16) !Entry {
    const notes = try allocator.alloc(Note, 1);
    notes[0] = .{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 };
    return .{ .melodic = .{ .track = track, .length_beats = 4.0, .notes = notes } };
}

test "push clears the redo branch" {
    const a = std.testing.allocator;
    var h: History = .{};
    defer h.deinit(a);

    h.push(a, try melodicEntry(a, 0));
    var undone = h.popUndo().?;
    h.parkRedo(a, undone);
    _ = &undone;
    try std.testing.expectEqual(@as(usize, 1), h.redo_stack.items.len);

    h.push(a, try melodicEntry(a, 1)); // new edit: redo history is gone
    try std.testing.expectEqual(@as(usize, 0), h.redo_stack.items.len);
    try std.testing.expectEqual(@as(usize, 1), h.undo_stack.items.len);
}

test "undo stack caps at max_entries, dropping the oldest" {
    const a = std.testing.allocator;
    var h: History = .{};
    defer h.deinit(a);

    var i: u16 = 0;
    while (i < max_entries + 8) : (i += 1) h.push(a, try melodicEntry(a, i));
    try std.testing.expectEqual(max_entries, h.undo_stack.items.len);
    // Oldest 8 fell off: the bottom entry is #8.
    try std.testing.expectEqual(@as(u16, 8), h.undo_stack.items[0].melodic.track);
}

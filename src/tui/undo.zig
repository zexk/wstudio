//! Undo/redo history for content edits (UI thread only).
//!
//! Snapshot-based: before a mutating edit, the App captures the whole state
//! of the domain being touched — one track's melodic pattern, one drum
//! machine's pattern bank, one arrangement lane, or one FX chain — and
//! pushes it here. Undo swaps the captured state with the live one (the
//! displaced state moves to the redo stack), so undo/redo walk the same
//! entries in both directions. `.param_nudge` is the odd one out: synth/
//! sampler params live on the audio thread, so it stores the one param's
//! absolute before-value and restores it through the same event path
//! automation already uses (see its own doc comment). Rapid
//! repeated nudges on the same param/unit coalesce into one entry — see
//! `history.zig`'s `noteParamNudge`/`noteFxNudge`. Track-level operations
//! (add/delete/instrument swap) and swing/mixer gain/pan are deliberately
//! out of scope.

const std = @import("std");
const ws = @import("wstudio");

const Note = ws.dsp.pattern.Note;
const DrumMachine = ws.dsp.DrumMachine;
const Clip = ws.Clip;
const Fx = ws.Fx;

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

/// Which FX chain an `.fx` entry targets — track/master/group index baked
/// in at capture time, so undo/redo apply to the right chain even if the
/// user has since navigated away from the FX view that made the edit.
pub const FxTarget = union(enum) {
    track: u16,
    master,
    group: u8,

    pub fn eql(a: FxTarget, b: FxTarget) bool {
        return switch (a) {
            .track => |ta| switch (b) { .track => |tb| ta == tb, else => false },
            .master => b == .master,
            .group => |ga| switch (b) { .group => |gb| ga == gb, else => false },
        };
    }
};

/// One FX chain's whole ordered unit list (deep copy, via `Fx.dupe` — same
/// payload-clone rule `Rack.dupe` uses for track duplication). Covers both
/// param nudges and structural edits (insert/remove/reorder/bypass) alike,
/// since either reshapes the same chain.
pub const FxState = struct {
    target: FxTarget,
    fx: Fx, // owned deep copy

    pub fn deinit(self: *FxState, allocator: std.mem.Allocator) void {
        self.fx.deinit(allocator);
    }
};

/// A coalesced run of h/l/H/L nudges on one synth/sampler param. `value`
/// is the ABSOLUTE param value `applyEntry` should restore (captured on
/// the control thread when the batch opened — see `PolySynth.paramValue`
/// and friends), sent through `engine.set_track_param_abs`; applying it
/// hands back the value it displaced as the entry parked on the opposite
/// stack, which works symmetrically for undo and redo. Absolute, not a
/// replayed delta: a delta lands wrong whenever any nudge in the batch
/// hit the param's clamp, and enum/toggle params treat any nonzero delta
/// as a single step, so a coalesced sum couldn't round-trip them.
pub const ParamNudgeState = struct {
    track: u16,
    id: u16,
    value: f32,
};

/// A synth/sampler param-nudge batch still open (cursor hasn't moved off
/// the param yet). `before` is the absolute value captured when the batch
/// opened; `steps` is the net signed delta dialed in so far, kept ONLY for
/// the flush-time no-op check (a batch that netted zero is dropped) —
/// that check must stay synchronous, since the nudges themselves are
/// queued commands the audio thread may not have applied yet.
pub const PendingParamNudge = struct {
    track: u16,
    id: u16,
    before: f32,
    steps: i32 = 0,
};

/// An FX param-nudge batch still open (cursor hasn't moved off this unit's
/// param row yet). `before` is the chain snapshot captured when the batch
/// started; flushing pushes it and clears this.
pub const PendingFxNudge = struct {
    target: FxTarget,
    focus: usize,
    param: usize,
    before: FxState, // owned deep copy

    pub fn deinit(self: *PendingFxNudge, allocator: std.mem.Allocator) void {
        self.before.deinit(allocator);
    }
};

/// How a structural track change (delete/swap) reshapes a track index
/// baked into an undo entry. Applied by `History.retarget` to every entry
/// on both stacks right after the change, so old entries keep pointing at
/// the same physical track instead of the wrong one once indices shift.
pub const TrackRemap = union(enum) {
    delete: u16,
    swap: struct { a: u16, b: u16 },

    /// The track's new index, or null if it no longer exists (delete only
    /// — a swap never removes a track).
    pub fn apply(self: TrackRemap, track: u16) ?u16 {
        return switch (self) {
            .delete => |del| if (track == del) null else if (track > del) track - 1 else track,
            .swap => |s| if (track == s.a) s.b else if (track == s.b) s.a else track,
        };
    }
};

pub const Entry = union(enum) {
    melodic: MelodicState,
    drum: DrumState,
    lane: LaneState,
    fx: FxState,
    param_nudge: ParamNudgeState,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .melodic => |*m| m.deinit(allocator),
            .drum => {},
            .lane => |*l| l.deinit(allocator),
            .fx => |*f| f.deinit(allocator),
            .param_nudge => {},
        }
    }

    pub fn label(self: *const Entry) []const u8 {
        return switch (self.*) {
            .melodic => "pattern",
            .drum => "drum",
            .lane => "clip",
            .fx => "fx",
            .param_nudge => "param",
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

    /// Remap every undo/redo entry's track index after a structural track
    /// change (see `TrackRemap`), dropping any entry whose track no longer
    /// exists. Returns how many entries were dropped, for a user-facing
    /// status message. Iterates back-to-front so mid-list removals don't
    /// disturb not-yet-visited indices.
    pub fn retarget(self: *History, allocator: std.mem.Allocator, remap: TrackRemap) usize {
        return retargetStack(&self.undo_stack, allocator, remap) +
            retargetStack(&self.redo_stack, allocator, remap);
    }
};

fn retargetStack(stack: *std.ArrayListUnmanaged(Entry), allocator: std.mem.Allocator, remap: TrackRemap) usize {
    var dropped: usize = 0;
    var i: usize = stack.items.len;
    while (i > 0) {
        i -= 1;
        var keep = true;
        switch (stack.items[i]) {
            .melodic => |*m| if (remap.apply(m.track)) |nt| { m.track = nt; } else { keep = false; },
            .drum => |*d| if (remap.apply(d.track)) |nt| { d.track = nt; } else { keep = false; },
            .lane => |*l| if (remap.apply(l.track)) |nt| { l.track = nt; } else { keep = false; },
            .param_nudge => |*p| if (remap.apply(p.track)) |nt| { p.track = nt; } else { keep = false; },
            .fx => |*f| switch (f.target) {
                .track => |t| if (remap.apply(t)) |nt| { f.target = .{ .track = nt }; } else { keep = false; },
                else => {},
            },
        }
        if (!keep) {
            var removed = stack.orderedRemove(i);
            removed.deinit(allocator);
            dropped += 1;
        }
    }
    return dropped;
}

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

test "retarget delete drops the deleted track's entry and shifts later ones down" {
    const a = std.testing.allocator;
    var h: History = .{};
    defer h.deinit(a);

    h.push(a, try melodicEntry(a, 0)); // named track deleted below: dropped
    h.push(a, try melodicEntry(a, 1)); // unaffected: below the deleted index
    h.push(a, try melodicEntry(a, 2)); // shifts down to 1

    const dropped = h.retarget(a, .{ .delete = 0 });
    try std.testing.expectEqual(@as(usize, 1), dropped);
    try std.testing.expectEqual(@as(usize, 2), h.undo_stack.items.len);
    // Original tracks 1 and 2 both shift down by one.
    try std.testing.expectEqual(@as(u16, 0), h.undo_stack.items[0].melodic.track);
    try std.testing.expectEqual(@as(u16, 1), h.undo_stack.items[1].melodic.track);
}

test "retarget swap exchanges two entries' track indices, drops nothing" {
    const a = std.testing.allocator;
    var h: History = .{};
    defer h.deinit(a);

    h.push(a, try melodicEntry(a, 1));
    h.push(a, try melodicEntry(a, 2));

    const dropped = h.retarget(a, .{ .swap = .{ .a = 1, .b = 2 } });
    try std.testing.expectEqual(@as(usize, 0), dropped);
    try std.testing.expectEqual(@as(u16, 2), h.undo_stack.items[0].melodic.track);
    try std.testing.expectEqual(@as(u16, 1), h.undo_stack.items[1].melodic.track);
}

test "retarget on an .fx entry only touches a .track target" {
    const a = std.testing.allocator;
    var h: History = .{};
    defer h.deinit(a);

    h.push(a, .{ .fx = .{ .target = .master, .fx = .{} } });
    h.push(a, .{ .fx = .{ .target = .{ .track = 2 }, .fx = .{} } });

    const dropped = h.retarget(a, .{ .delete = 0 });
    try std.testing.expectEqual(@as(usize, 0), dropped);
    try std.testing.expectEqual(.master, std.meta.activeTag(h.undo_stack.items[0].fx.target));
    try std.testing.expectEqual(@as(u16, 1), h.undo_stack.items[1].fx.target.track);
}

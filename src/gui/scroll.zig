const std = @import("std");
const zgui = @import("zgui");

/// Keep the row at `top_y` (screen space, `getCursorScreenPos()[1]` read
/// just before the row is submitted) inside the window or child being drawn,
/// the way a terminal pager does: nudge the scroll only when the row would
/// otherwise fall outside it.
///
/// ImGui has no "scroll into view if off-screen" of its own. `setScrollHereY`
/// re-centres on the item every single frame, which pins the viewport to the
/// cursor and leaves the wheel and the scrollbar with nothing to do - the
/// right trade for a modal picker, the wrong one for a workspace view you
/// also want to scroll by hand. Without either, a view just doesn't follow:
/// `j` past the fold moves the cursor into content ImGui is happily clipping
/// away, and the frontend looks frozen.
/// Screen-space band the focused param occupied this frame, if the view drew
/// one. Recorded by the widgets that take a `focused` flag and consumed once
/// by `scrollFocusIntoView`.
///
/// Deferred rather than acted on in place because a param usually sits
/// inside a non-scrolling card child, while the window that actually
/// scrolls is the workspace one outside it - `setScrollY` from inside the
/// child would move a scrollbar that doesn't exist.
var focus_row: ?struct { top: f32, height: f32 } = null;

pub fn noteFocusRow(focused: bool, top: f32, height: f32) void {
    if (focused) focus_row = .{ .top = top, .height = height };
}

/// Drop whatever was recorded without acting on it - for the frame a picker
/// overlay is up and the base view underneath it must not be scrolled.
pub fn clearFocusRow() void {
    focus_row = null;
}

/// Bring the focused param recorded this frame on screen. Call once per
/// frame from the scrolling window, after the view has finished drawing.
pub fn scrollFocusIntoView() void {
    const row = focus_row orelse return;
    focus_row = null;
    keepRowVisible(row.top, row.height);
}

pub fn keepRowVisible(top_y: f32, height: f32) void {
    const win_top = zgui.getWindowPos()[1];
    const pad = zgui.getStyle().window_padding[1];
    const current = zgui.getScrollY();
    const target = rowScrollTarget(top_y, height, win_top, zgui.getWindowSize()[1], pad, current, zgui.getScrollMaxY());
    if (target != current) zgui.setScrollY(target);
}

fn rowScrollTarget(top_y: f32, height: f32, win_top: f32, win_height: f32, pad: f32, current: f32, max: f32) f32 {
    const delta: f32 = if (top_y < win_top + pad)
        top_y - (win_top + pad)
    else if (top_y + height > win_top + win_height - pad)
        (top_y + height) - (win_top + win_height - pad)
    else
        return current;
    return std.math.clamp(current + delta, 0, max);
}

test "cursor following scrolls only when focused row leaves viewport" {
    try std.testing.expectEqual(@as(f32, 40), rowScrollTarget(130, 20, 100, 100, 10, 40, 200));
    // Row bottom 205, viewport bottom minus padding 190: scroll the 15 that
    // brings it flush, not a padding's worth more (this case asserted 65 and
    // had never run - see the test block in gui/app.zig).
    try std.testing.expectEqual(@as(f32, 55), rowScrollTarget(185, 20, 100, 100, 10, 40, 200));
    try std.testing.expectEqual(@as(f32, 20), rowScrollTarget(70, 20, 100, 100, 10, 60, 200));
    try std.testing.expectEqual(@as(f32, 0), rowScrollTarget(0, 20, 100, 100, 10, 5, 200));
    try std.testing.expectEqual(@as(f32, 200), rowScrollTarget(400, 20, 100, 100, 10, 190, 200));
}

/// A display pane (waveform, spectrum, transfer curve) that gives its height
/// back to whatever is drawn under it, so an editor's modules stay on one
/// screen instead of the view growing an outer scrollbar: a module is a unit,
/// and the thing that yields is the pane that has pixels to spare.
///
/// One instance per pane, kept across frames: the panels under it size to
/// their own content, so how much room they need is only known once they have
/// been drawn. Ask for `height` where the pane is drawn, call `settle` once
/// the rest of the view has been submitted.
///
/// For content that grows back into whatever the pane yields (fx.zig's param
/// cards stretch to fill their row) measuring is the wrong tool - the two just
/// chase each other. Reserve that content's floor up front instead, the way
/// `fx.zig`'s `gridFloor` does.
pub const PaneFit = struct {
    /// Height of everything below the pane, measured on the previous frame.
    below: f32 = 0,
    /// How much the view still overflowed its window after that (window/child
    /// padding this layout can't see from here), taken straight off the pane's
    /// height until it fits. Sticky: a corrected overflow reads as zero, so
    /// re-deriving it each frame would flip the pane between two heights
    /// forever.
    trim: f32 = 0,
    window_h: f32 = 0,
    key: u64 = 0,

    /// Farthest the trim will go, so a layout that can never fit shrinks the
    /// pane to its floor instead of running away.
    const max_trim: f32 = 240;

    /// This frame's pane height: whatever the modules leave over, never past
    /// what the pane is still readable at (`min`) or wants (`max`).
    pub fn height(self: *const PaneFit, min: f32, max: f32) f32 {
        return std.math.clamp(zgui.getContentRegionAvail()[1] - self.below - self.trim, min, max);
    }

    /// Close the layout: measure what was drawn below the pane (`below_top` is
    /// `getCursorPosY()` read where the pane's siblings start) and settle the
    /// trim. `key` says what is on screen - a different unit, target or band
    /// count divides the room up differently, so its trim starts over rather
    /// than being inherited.
    ///
    /// A new measurement also starts the trim over, including the very first
    /// frame's (which was taken with nothing below the pane at all): a trim
    /// carried over from that one leaves the pane at its floor with the room it
    /// gave up going to nobody.
    pub fn settle(self: *PaneFit, below_top: f32, key: u64) void {
        const below = zgui.getCursorPosY() - below_top;
        // How far past the window the view ran, taken from the content region
        // rather than `getScrollMaxY`: ImGui's scroll max comes from last
        // frame's content size, and an overflow arriving a frame after the
        // measurement it belongs to trims the pane for a layout that has
        // already been corrected.
        const overflow = @max(0, -zgui.getContentRegionAvail()[1]);
        const win_h = zgui.getWindowHeight();
        self.trim = nextTrim(self.trim, overflow, below != self.below or win_h != self.window_h or key != self.key);
        self.below = below;
        self.window_h = win_h;
        self.key = key;
    }
};

/// The trim rule on its own: a restart measures again from nothing, anything
/// else adds this frame's overflow (zero once it fits, which is what makes it
/// settle).
fn nextTrim(current: f32, overflow: f32, restart: bool) f32 {
    if (restart) return 0;
    return @min(current + overflow, PaneFit.max_trim);
}

test "a pane's trim settles on an overflow and starts over on a new measurement" {
    // Overflow accumulates until the view fits, then holds - re-deriving it
    // from a corrected (zero) overflow would flip the pane's height forever.
    var trim = nextTrim(0, 11, false);
    try std.testing.expectEqual(@as(f32, 11), trim);
    trim = nextTrim(trim, 11, false);
    try std.testing.expectEqual(@as(f32, 22), trim);
    trim = nextTrim(trim, 0, false);
    try std.testing.expectEqual(@as(f32, 22), trim);
    // Capped, so a layout that can never fit shrinks the pane to its floor
    // instead of running away.
    try std.testing.expectEqual(PaneFit.max_trim, nextTrim(200, 90, false));
    // A resized window, a different unit on screen, or simply a fresh
    // measurement of what is below: different room to divide up, measure again.
    try std.testing.expectEqual(@as(f32, 0), nextTrim(22, 11, true));
}

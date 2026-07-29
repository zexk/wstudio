//! Value formatters both frontends print verbatim. Anything that turns a
//! parameter into user-facing text and would otherwise be re-typed per view
//! belongs here, so a change to how a value reads lands everywhere at once.

const std = @import("std");
// Through the module, not a relative path: `src/` files belong to the
// `wstudio` module, and importing one directly would put it in two modules.
const midi = @import("wstudio").midi;

/// Below this a pan is "centered" - a knob or a nudge can leave a value a
/// hair off zero, and reading "L0%" there is noise, not information.
pub const pan_center_epsilon: f32 = 0.005;

/// Sentinel a param table puts in a `gui_format` slot to ask for `panLabel`
/// instead of a printf float (see gui/widgets.zig's `knobFormatValue`) - it
/// lives here so the tables in ui/ can name it without importing the GUI.
pub const pan_cfmt: [:0]const u8 = "%pan";

/// Mixer-style pan readout: "C", or the side plus how far it leans.
pub fn panLabel(buf: []u8, pan: f32) []const u8 {
    if (@abs(pan) < pan_center_epsilon) return "C";
    const pct: u32 = @intFromFloat(@abs(pan) * 100.0);
    return std.fmt.bufPrint(buf, "{c}{d}%", .{ panLetter(pan)[0], pct }) catch "C";
}

/// Same sentinel trick as `pan_cfmt`, for the bipolar pad tone filter: a raw
/// float says nothing about which side of the knob is a low-pass.
pub const filter_cfmt: [:0]const u8 = "%filter";

/// Readout for `dsp.Pad.filter`: "off" at the centre, else the direction plus
/// how far the knob is pushed ("LP 60%", "HP 25%").
pub fn filterLabel(buf: []u8, f: f32) []const u8 {
    if (@abs(f) < pan_center_epsilon) return "off";
    const pct: u32 = @intFromFloat(@abs(f) * 100.0);
    return std.fmt.bufPrint(buf, "{s} {d}%", .{ if (f < 0) "LP" else "HP", pct }) catch "off";
}

/// Same sentinel trick as `pan_cfmt`, for a param whose value is a MIDI note
/// number: a sampler's root note is a pitch, and "60" is not how anyone
/// names a pitch.
pub const note_cfmt: [:0]const u8 = "%note";

/// Readout for a MIDI note number: the note name, plus the raw number, since
/// the number is what `:set`-style commands and the automation lane speak.
pub fn noteLabel(buf: []u8, value: f32) []const u8 {
    const note: u7 = @intFromFloat(std.math.clamp(value, 0, 127));
    var name_buf: [8]u8 = undefined;
    const name = midi.noteName(note, &name_buf);
    return std.fmt.bufPrint(buf, "{s} ({d})", .{ name, note }) catch name;
}

test "note formatting names the pitch and keeps the number" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("C4 (60)", noteLabel(&buf, 60));
    try std.testing.expectEqualStrings("C-1 (0)", noteLabel(&buf, -3));
    try std.testing.expectEqualStrings("G9 (127)", noteLabel(&buf, 200));
}

/// Just the side, for the status line's one-column-wide slot.
pub fn panLetter(pan: f32) []const u8 {
    if (@abs(pan) < pan_center_epsilon) return "C";
    return if (pan < 0) "L" else "R";
}

test "pan formatting" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("C", panLabel(&buf, 0.0));
    try std.testing.expectEqualStrings("C", panLabel(&buf, -0.001));
    try std.testing.expectEqualStrings("L42%", panLabel(&buf, -0.42));
    try std.testing.expectEqualStrings("R100%", panLabel(&buf, 1.0));
    try std.testing.expectEqualStrings("C", panLetter(0.004));
    try std.testing.expectEqualStrings("L", panLetter(-0.5));
    try std.testing.expectEqualStrings("R", panLetter(0.5));
}

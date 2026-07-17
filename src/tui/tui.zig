//! TUI rendering facade. The shared palette and primitives live in style.zig;
//! each view's renderer lives in views/<name>.zig. This module re-exports them
//! so callers (app.zig) keep using `tui.drawX` / `tui.endLine` / etc.
//!
//! View renderers that need App fields take `app: anytype`, so no view module
//! imports app.zig - the compiler instantiates each with *App at the call site
//! and type-checks the field accesses there.

const std = @import("std");
const ws = @import("wstudio");
const Transport = ws.Transport;
const style = @import("style.zig");
const icons = @import("../ui/icons.zig");
const status = @import("../ui/status.zig");

const rst = style.rst;
const bold = style.bold;
const dim = style.dim;
const acc = style.acc;
const yel = style.yel;

// Shared palette consts / primitives re-exported for callers.
pub const meter = style.meter;

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

/// Writes the header's content only (no trailing newline) - the caller
/// (app.zig) captures it into a scratch buffer and renders it as a
/// full-width chrome bar via `style.writeChromeRow`.
pub fn drawHeader(
    w: *std.Io.Writer,
    title: []const u8,
    transport: *const Transport,
    audio_label: []const u8,
    master_gain_db: f32,
    dirty: bool,
) !void {
    const vol_sign: []const u8 = if (master_gain_db >= 0) "+" else "";
    try w.writeAll(bold ++ " " ++ icons.logo ++ " wstudio" ++ rst);
    try w.writeAll(dim ++ "  " ++ rst);
    try w.writeAll(title);
    if (dirty) try w.writeAll(" " ++ yel ++ icons.warn ++ rst);
    try w.writeAll(dim ++ "   " ++ icons.tempo ++ " " ++ rst);
    try w.print("{d:.0}", .{transport.tempo_bpm});
    try w.writeAll(dim ++ "  " ++ rst);
    try w.print("{d}/{d}", .{
        transport.time_signature.beats_per_bar,
        transport.time_signature.beat_unit,
    });
    try w.writeAll(dim ++ "   " ++ icons.master ++ " " ++ rst);
    try w.print("{s}{d:.0}dB", .{ vol_sign, master_gain_db });
    try w.writeAll(dim ++ "   " ++ rst);
    try w.writeAll(acc);
    try w.writeAll(audio_label);
}

// ---------------------------------------------------------------------------
// View renderers (re-exported from views/*.zig)
// ---------------------------------------------------------------------------

const tracks = @import("views/tracks.zig");
const picker = @import("views/picker.zig");
const drum = @import("views/drum.zig");
const slicer = @import("views/slicer.zig");
const help = @import("views/help.zig");
const spectrum = @import("views/spectrum.zig");
const synth = @import("views/synth.zig");
const piano = @import("views/piano.zig");
const sampler = @import("views/sampler.zig");
const arrangement = @import("views/arrangement.zig");
const browser = @import("views/browser.zig");
const automation = @import("views/automation.zig");
const preset_picker = @import("views/preset_picker.zig");

pub const drawTracks = tracks.drawTracks;
pub const drawInstrumentPicker = picker.drawInstrumentPicker;
pub const drawFxPicker = picker.drawFxPicker;
pub const drawSynthFxPicker = picker.drawSynthFxPicker;
pub const drawDrumGrid = drum.drawDrumGrid;
pub const drawSlicerGrid = slicer.drawSlicerGrid;
pub const drawHelp = help.drawHelp;
pub const helpSearch = help.search;
pub const drawFxView = spectrum.drawFxView;
pub const drawSynthEditor = synth.drawSynthEditor;
pub const drawPianoRoll = piano.drawPianoRoll;
pub const drawSamplerEditor = sampler.drawSamplerEditor;
pub const drawArrangement = arrangement.drawArrangement;
pub const drawFileBrowser = browser.drawFileBrowser;
pub const drawAutomation = automation.drawAutomation;
pub const drawAutomationParamPicker = automation.drawAutomationParamPicker;
pub const drawPresetPicker = preset_picker.drawPresetPicker;

// Status renderers are shared with the GUI (which strips the SGR codes and
// re-renders the plain text) - the model lives in ui/status.zig, not per-view.
pub const drawTracksStatus = status.drawTracksStatus;
pub const drawPickerStatus = status.drawPickerStatus;
pub const drawDrumStatus = status.drawDrumStatus;
pub const drawSlicerStatus = status.drawSlicerStatus;
pub const drawHelpStatus = status.drawHelpStatus;
pub const drawFxStatus = status.drawFxStatus;
pub const drawSynthStatus = status.drawSynthStatus;
pub const drawPianoRollStatus = status.drawPianoRollStatus;
pub const drawSamplerStatus = status.drawSamplerStatus;
pub const drawArrangementStatus = status.drawArrangementStatus;
pub const drawFileBrowserStatus = status.drawFileBrowserStatus;
pub const drawAutomationStatus = status.drawAutomationStatus;
pub const drawPresetPickerStatus = status.drawPresetPickerStatus;

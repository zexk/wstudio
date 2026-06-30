//! TUI rendering facade. The shared palette and primitives live in style.zig;
//! each view's renderer lives in views/<name>.zig. This module re-exports them
//! so callers (app.zig) keep using `tui.drawX` / `tui.endLine` / etc.
//!
//! View renderers that need App fields take `app: anytype`, so no view module
//! imports app.zig — the compiler instantiates each with *App at the call site
//! and type-checks the field accesses there.

const std = @import("std");
const ws = @import("wstudio");
const Project = ws.Project;
const Transport = ws.Transport;
const style = @import("style.zig");

const rst = style.rst;
const bold = style.bold;
const dim = style.dim;
const acc = style.acc;

// Shared palette consts / primitives re-exported for callers.
pub const spectrum_rows = style.spectrum_rows;
pub const spectrum_band_count = style.spectrum_band_count;
pub const synth_param_count = style.synth_param_count;
pub const endLine = style.endLine;
pub const hr = style.hr;
pub const meter = style.meter;

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

pub fn drawHeader(
    w: *std.Io.Writer,
    project: *const Project,
    transport: *const Transport,
    audio_label: []const u8,
    master_gain_db: f32,
) !void {
    const vol_sign: []const u8 = if (master_gain_db >= 0) "+" else "";
    try w.writeAll(bold ++ " wstudio" ++ rst);
    try w.writeAll(dim ++ "  " ++ rst);
    try w.writeAll(project.name);
    try w.writeAll(dim ++ "   bpm " ++ rst);
    try w.print("{d:.0}", .{transport.tempo_bpm});
    try w.writeAll(dim ++ "  " ++ rst);
    try w.print("{d}/{d}", .{
        transport.time_signature.beats_per_bar,
        transport.time_signature.beat_unit,
    });
    try w.writeAll(dim ++ "   vol " ++ rst);
    try w.print("{s}{d:.0}dB", .{ vol_sign, master_gain_db });
    try w.writeAll(dim ++ "   " ++ rst);
    try w.writeAll(acc);
    try w.writeAll(audio_label);
    try endLine(w);
}

// ---------------------------------------------------------------------------
// View renderers (re-exported from views/*.zig)
// ---------------------------------------------------------------------------

const tracks = @import("views/tracks.zig");
const picker = @import("views/picker.zig");
const drum = @import("views/drum.zig");
const help = @import("views/help.zig");
const spectrum = @import("views/spectrum.zig");
const synth = @import("views/synth.zig");
const piano = @import("views/piano.zig");
const sampler = @import("views/sampler.zig");

pub const drawTracks = tracks.drawTracks;
pub const drawTracksStatus = tracks.drawTracksStatus;
pub const drawInstrumentPicker = picker.drawInstrumentPicker;
pub const drawDrumGrid = drum.drawDrumGrid;
pub const drawDrumStatus = drum.drawDrumStatus;
pub const drawHelp = help.drawHelp;
pub const drawSpectrumView = spectrum.drawSpectrumView;
pub const drawSpectrumStatus = spectrum.drawSpectrumStatus;
pub const drawSynthEditor = synth.drawSynthEditor;
pub const drawSynthStatus = synth.drawSynthStatus;
pub const drawPianoRoll = piano.drawPianoRoll;
pub const drawPianoRollStatus = piano.drawPianoRollStatus;
pub const drawSamplerEditor = sampler.drawSamplerEditor;
pub const drawSamplerStatus = sampler.drawSamplerStatus;

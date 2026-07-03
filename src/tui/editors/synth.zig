//! Synth-editor input: param row navigation ({/} jump sections), h/l nudges
//! routed over the engine command queue to the audio thread, and the
//! cursor-row/scroll math shared with the renderer in views/synth.zig.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const style = @import("../style.zig");
const App = @import("../app.zig").App;
const spectrum = @import("spectrum.zig");
const piano = @import("piano.zig");

pub fn handleKey(app: *App, key: modal_mod.Key) bool {
    switch (key) {
        .escape => { app.view = .tracks; return true; },
        .char => |c| switch (c) {
            // Block insert mode — piano keys conflict with parameter navigation.
            'i' => return true,
            's' => { spectrum.switchToTrack(app, app.synth_track); return true; },
            // p opens the piano roll for this track (matches p in the tracks view);
            // e in the piano roll comes back here, so synth <-> roll is bidirectional.
            'p' => { piano.switchTo(app, app.synth_track); return true; },
            // j/k rows and h/l nudges take a vim count prefix (3j, 5l, …).
            'j' => { moveCursor(app, app.takeCount()); return true; },
            'k' => { moveCursor(app, -app.takeCount()); return true; },
            'h' => { adjustParam(app, -app.takeCount()); return true; },
            'l' => { adjustParam(app, app.takeCount()); return true; },
            'H' => { adjustParam(app, -10 * app.takeCount()); return true; },
            'L' => { adjustParam(app, 10 * app.takeCount()); return true; },
            '}', '{' => {
                const section_starts = [_]u8{ 0, 6, 14, 16, 20, 24, 28, 32, 34, 36, 38 };
                if (c == '}') {
                    for (section_starts) |s| {
                        if (s > app.synth_cursor) {
                            app.synth_cursor = s;
                            break;
                        }
                    }
                } else {
                    var sec_idx: usize = 0;
                    for (section_starts, 0..) |s, idx| {
                        if (s <= app.synth_cursor) sec_idx = idx;
                    }
                    if (app.synth_cursor == section_starts[sec_idx] and sec_idx > 0) {
                        app.synth_cursor = section_starts[sec_idx - 1];
                    } else {
                        app.synth_cursor = section_starts[sec_idx];
                    }
                }
                updateScroll(app);
                return true;
            },
            else => return false,
        },
        else => return false,
    }
}

/// Move the param cursor by `delta` rows, clamped to the param list.
fn moveCursor(app: *App, delta: i32) void {
    app.synth_cursor = @intCast(std.math.clamp(
        @as(i32, app.synth_cursor) + delta, 0, style.synth_param_count - 1,
    ));
    updateScroll(app);
}

/// Row index of `synth_cursor` within drawSynthEditor's output (0-based).
/// Must stay in sync with the layout in tui.drawSynthEditor.
pub fn paramRow(cursor: u8) usize {
    return switch (cursor) {
        0...5  => 2 + @as(usize, cursor),          // OSC A section (header at row 1)
        6...13 => 9 + @as(usize, cursor - 6),      // OSC B (header at row 8)
        14...15 => 18 + @as(usize, cursor - 14),   // MOD (header at 17)
        16...19 => 21 + @as(usize, cursor - 16),   // ENV (header at 20)
        20...23 => 26 + @as(usize, cursor - 20),   // FILTER (header at 25)
        24...27 => 31 + @as(usize, cursor - 24),   // FENV (header at 30)
        28...31 => 36 + @as(usize, cursor - 28),   // LFO (header at 35)
        32...33 => 41 + @as(usize, cursor - 32),   // VOICE (header at 40)
        34...35 => 44 + @as(usize, cursor - 34),   // SUB (header at 43)
        36...37 => 47 + @as(usize, cursor - 36),   // NOISE (header at 46)
        38      => 50,                              // OUT (header at 49)
        else    => 0,
    };
}

pub fn updateScroll(app: *App) void {
    // Will be called with an actual max_rows at draw time; use 20 as a safe
    // minimum so the scroll is kept reasonable even before the first draw.
    const max_rows: usize = 20;
    const row = paramRow(app.synth_cursor);
    if (row < app.synth_scroll) app.synth_scroll = row;
    if (row >= app.synth_scroll + max_rows) app.synth_scroll = row - max_rows + 1;
}

/// Nudge the selected synth-editor parameter. The change is routed over the
/// engine command queue and applied on the audio thread (PolySynth.adjustParam)
/// so it never races the block reader — the editor view reflects it on the
/// next frame. See engine.Command.set_track_param.
fn adjustParam(app: *App, steps: i32) void {
    if (app.synth_track >= app.session.racks.items.len) return;
    const rack = app.session.racks.items[app.synth_track];
    switch (rack.instrument) {
        .poly_synth => {},
        else => return,
    }
    app.dirty = true;
    _ = app.session.engine.send(.{ .set_track_param = .{
        .track = app.synth_track,
        .id    = app.synth_cursor,
        .steps = steps,
    } });
}

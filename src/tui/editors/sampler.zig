//! Sampler-editor input for both targets — a drum machine pad or a standalone
//! Sampler: param row navigation, h/l nudges (routed to the audio thread),
//! pad jumps and audition. The render half lives in views/sampler.zig.

const ws = @import("wstudio");
const modal_mod = ws.input;
const DrumMachine = ws.dsp.DrumMachine;
const Sampler = ws.dsp.Sampler;
const App = @import("../app.zig").App;

/// Number of editable params for the sampler editor's current target.
fn paramCount(app: *App) u8 {
    return switch (app.sampler_target) {
        .drum => DrumMachine.pad_param_count,
        .sampler => Sampler.param_count,
    };
}

/// Sampler editor: j/k pick a param row, h/l/H/L nudge it. For a drum pad,
/// 1–8 jump pads (shared `drum_cursor[0]`) and esc/e return to the drum
/// grid; for a standalone Sampler, esc/e return to the tracks view. p
/// auditions the current pad / the sampler's root note.
pub fn handleKey(app: *App, key: modal_mod.Key) bool {
    const is_drum = app.sampler_target == .drum;
    switch (key) {
        .escape => { app.view = if (is_drum) .drum_grid else .tracks; return true; },
        .char => |c| switch (c) {
            // Block insert mode — piano keys conflict with param navigation.
            'i' => return true,
            'e' => { app.view = if (is_drum) .drum_grid else .tracks; return true; },
            'j' => {
                if (app.sampler_param + 1 < paramCount(app)) app.sampler_param += 1;
                return true;
            },
            'k' => { if (app.sampler_param > 0) app.sampler_param -= 1; return true; },
            'h' => { adjustParam(app, -1); return true; },
            'l' => { adjustParam(app, 1); return true; },
            'H' => { adjustParam(app, -10); return true; },
            'L' => { adjustParam(app, 10); return true; },
            '1'...'8' => {
                if (is_drum) {
                    const pad: u8 = c - '1';
                    if (pad < DrumMachine.max_pads) app.drum_cursor[0] = pad;
                }
                return true;
            },
            'p' => { preview(app); return true; },
            else => return false,
        },
        else => return false,
    }
}

/// Audition the sampler editor's current target.
fn preview(app: *App) void {
    switch (app.sampler_target) {
        .drum => |t| {
            _ = app.session.engine.send(.{ .note_on = .{
                .track = t, .note = @intCast(app.drum_cursor[0]), .velocity = 0.9,
            } });
        },
        .sampler => |t| {
            const root: u7 = if (app.editingSampler()) |s| s.root_note else 60;
            app.playNote(t, root, app.now_ns);
        },
    }
}

/// Nudge the selected sampler param. Routed over the command queue so the
/// edit lands on the audio thread (DrumMachine/Sampler.adjustParam), never
/// racing the block reader — mirrors the synth editor's adjustParam.
pub fn adjustParam(app: *App, steps: i32) void {
    app.dirty = true;
    switch (app.sampler_target) {
        .drum => |t| {
            const id = DrumMachine.paramId(app.drum_cursor[0], app.sampler_param);
            _ = app.session.engine.send(.{ .set_track_param = .{ .track = t, .id = id, .steps = steps } });
        },
        .sampler => |t| {
            _ = app.session.engine.send(.{ .set_track_param = .{ .track = t, .id = app.sampler_param, .steps = steps } });
        },
    }
}

pub fn handleMouse(app: *App, ev: modal_mod.MouseEvent, row: usize, cols: u16) void {
    _ = app;
    _ = ev;
    _ = row;
    _ = cols;
}

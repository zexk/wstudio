//! SoundFont-editor input for both targets - j/k picks a param row (GAIN/
//! PAN/TRANSPOSE/PRESET), h/l/H/L nudges it (routed to the audio thread,
//! same as every other instrument editor), `f` opens the searchable preset
//! picker (editors/preset_picker.zig's `.soundfont` Kind). The render half
//! lives in views/soundfont.zig. Loading a .sf2 and jumping straight to a
//! preset by bank/program are `:load`/`:sf-preset` (commands.zig), not keys
//! here - same convention the synth editor's wavetable import already
//! follows.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const history = @import("../history.zig");
const preset_picker = @import("preset_picker.zig");

/// GAIN, PAN, TRANSPOSE, PRESET - see dsp/soundfont_player.zig's `param_count`.
pub const param_count: u8 = ws.dsp.SoundfontPlayer.param_count;

pub fn handleKey(app: *App, key: modal_mod.Key) bool {
    switch (key) {
        .escape => {
            history.flushParamNudge(app);
            app.view = .tracks;
            return true;
        },
        .ctrl_r => {
            history.doRedo(app);
            return true;
        },
        .char => |c| switch (c) {
            'i' => return true, // block insert mode, same as the sampler editor
            'e' => {
                history.flushParamNudge(app);
                app.view = .tracks;
                return true;
            },
            'u' => {
                history.doUndo(app);
                return true;
            },
            'U' => {
                history.doRedo(app);
                return true;
            },
            'j' => {
                moveCursor(app, app.takeCount());
                return true;
            },
            'k' => {
                moveCursor(app, -app.takeCount());
                return true;
            },
            'h' => {
                adjustParam(app, -app.takeCount());
                return true;
            },
            'l' => {
                adjustParam(app, app.takeCount());
                return true;
            },
            'H' => {
                adjustParam(app, -10 * app.takeCount());
                return true;
            },
            'L' => {
                adjustParam(app, 10 * app.takeCount());
                return true;
            },
            'g' => {
                history.flushParamNudge(app);
                app.soundfont_param = 0;
                return true;
            },
            'G' => {
                history.flushParamNudge(app);
                app.soundfont_param = param_count - 1;
                return true;
            },
            'a' => {
                preview(app);
                return true;
            },
            'f' => {
                history.flushParamNudge(app);
                const sf = app.editingSoundfont() orelse return true;
                if (sf.presetCount() == 0) {
                    app.setStatus("no soundfont loaded - :load first", .{});
                    return true;
                }
                preset_picker.open(app, .soundfont, app.soundfont_track);
                return true;
            },
            else => return false,
        },
        else => return false,
    }
}

fn moveCursor(app: *App, delta: i32) void {
    app.soundfont_param = @intCast(ws.input.clampDelta(app.soundfont_param, delta, @as(i64, param_count) - 1));
}

/// Audition at the piano roll's last cursor pitch (whatever the user was
/// last looking at, even from another track) - falls back to C4 the same
/// way the sampler editor falls back to a pad's own root note.
fn preview(app: *App) void {
    const track = app.soundfont_track;
    app.playNote(track, app.piano_cursor_pitch, app.now_ns);
}

/// Nudge the selected param. Routed over the command queue so the edit
/// lands on the audio thread (SoundfontPlayer.adjustParam), never racing the
/// block reader - mirrors every other instrument editor's adjustParam.
pub fn adjustParam(app: *App, steps: i32) void {
    app.dirty = true;
    const track = app.soundfont_track;
    history.noteParamNudge(app, track, app.soundfont_param, steps);
    _ = app.session.engine.send(.{ .set_track_param = .{ .track = track, .id = app.soundfont_param, .steps = steps } });
}

/// Click a param row to select it; scroll nudges (ctrl+scroll = coarse,
/// matching H/L) - same shape as the sampler editor's mouse handling, minus
/// the waveform panel (soundfont has no per-region drag surface).
pub fn handleMouse(app: *App, ev: modal_mod.MouseEvent, row: usize) void {
    // Row 0 is the title; params start at row 1 - see views/soundfont.zig.
    if (row == 0 or row - 1 >= param_count) {
        if (ev.kind == .scroll_up or ev.kind == .scroll_down) return;
        return;
    }
    const p: u8 = @intCast(row - 1);
    switch (ev.kind) {
        .press => {
            history.flushParamNudge(app);
            app.soundfont_param = p;
        },
        .scroll_up, .scroll_down => {
            app.soundfont_param = p;
            const dir: i32 = if (ev.kind == .scroll_up) 1 else -1;
            adjustParam(app, dir * (if (ev.ctrl) @as(i32, 10) else 1));
        },
        else => {},
    }
}

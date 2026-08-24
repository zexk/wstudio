//! SoundFont-editor input for both targets - j/k picks a param row (GAIN/
//! PAN/TRANSPOSE/PRESET), h/l/H/L nudges it (routed to the audio thread,
//! same as every other instrument editor), `f` opens the searchable preset
//! picker (editors/preset_picker.zig's `.soundfont`/`.acoustic` Kind - one
//! editor serves both instruments, they differ only in what `f` lists and
//! where the audio comes from). The render half
//! lives in views/soundfont.zig. Loading a .sf2 and jumping straight to a
//! preset by bank/program are `:load`/`:sf-preset` (commands.zig), not keys
//! here - same convention the synth editor's wavetable import already
//! follows.

const ws = @import("wstudio");
const modal_mod = ws.input;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const history = @import("../history.zig");
const commands_load = @import("../commands/load.zig");
const preset_picker = @import("preset_picker.zig");
const spectrum = @import("fx_editor.zig");
const piano = @import("piano.zig");

/// GAIN, PAN, TRANSPOSE, PRESET - see dsp/soundfont_player.zig's `param_count`.
pub const param_count: u8 = ws.dsp.SoundfontPlayer.param_count;

pub fn handleKey(app: *App, key: modal_mod.Key) bool {
    // Multi-key prefixes (docs/editing-grammar.md): `g` armed below drains
    // on the next key (gg = first param, gG = last). An unknown pair falls
    // through, so a prefix never eats a key it doesn't own.
    if (app.takePrefix(key)) |p| switch (p) {
        'g' => switch (key.char) {
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
            else => {},
        },
        else => {},
    };
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
        // Empty editor has nothing to edit, so enter opens its browser.
        .enter => {
            const sf = app.editingSoundfont();
            if (sf != null and sf.?.presetCount() > 0) return false;
            commands_load.cmdLoad(app, "");
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
            // g/G are a two-key pair (gg = first param, gG = last): 'g'
            // arms the prefix, the follow-up key drains it above.
            'g' => {
                _ = app.armPrefix('g');
                return true;
            },
            'a' => {
                preview(app);
                return true;
            },
            // s/p: the same sideways navigation the synth and sampler editors
            // bind - this track's FX chain and its piano roll.
            's' => {
                history.flushParamNudge(app);
                spectrum.switchToTrack(app, app.soundfont_track);
                return true;
            },
            'p' => {
                history.flushParamNudge(app);
                piano.switchTo(app, app.soundfont_track);
                return true;
            },
            'f' => {
                history.flushParamNudge(app);
                const sf = app.editingSoundfont() orelse return true;
                // An acoustic track always has banks to browse; a .sf2 one
                // has nothing to list until a font is loaded.
                if (sf.presetCount() == 0 and app.session.racks.items[app.soundfont_track].instrument == .soundfont) {
                    app.setStatus("no soundfont loaded - :load first", .{});
                    return true;
                }
                preset_picker.openForTrack(app, app.soundfont_track);
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

/// View-content row of each param, mirroring views/soundfont.zig's emission
/// order: title(0), "OUT" section(1), gain/pan/transpose(2-4), "PROGRAM"
/// section(5), preset(6). The section headers are why this is a table and
/// not `row - 1` - that older form handed the OUT header row param 0 and
/// shifted every real param row down by one, so clicking a param selected
/// the one above it. Same shape as the sampler editor's `paramRelRow`,
/// which has always walked its own section headers.
const param_rows = [_]usize{ 2, 3, 4, 6 };

comptime {
    if (param_rows.len != param_count) @compileError("soundfont param row table is out of sync with param_count");
}

/// The row table alone, without the font-loaded gate `paramAtRow` applies -
/// tui/app_tests.zig checks the mapping here since a test app has no .sf2
/// to load.
pub fn rowParamForTest(row: usize) ?u8 {
    for (param_rows, 0..) |r, i| {
        if (r == row) return @intCast(i);
    }
    return null;
}

/// The param at view row `row`, or null for the title, a section header, or
/// the preset detail line under it. Null too when no font is loaded: the
/// view draws its empty state instead of any param row.
fn paramAtRow(app: *App, row: usize) ?u8 {
    const sf = app.editingSoundfont() orelse return null;
    if (sf.presetCount() == 0) return null;
    for (param_rows, 0..) |r, i| {
        if (r == row) return @intCast(i);
    }
    return null;
}

/// Click a param row to select it; scroll nudges (ctrl+scroll = coarse,
/// matching H/L) - same shape as the sampler editor's mouse handling, minus
/// the waveform panel (soundfont has no per-region drag surface).
pub fn handleMouse(app: *App, ev: modal_mod.MouseEvent, row: usize) void {
    const p = paramAtRow(app, row) orelse return;
    switch (ev.kind) {
        .press => {
            history.flushParamNudge(app);
            app.soundfont_param = p;
            if (ev.button == .middle) resetMouseParam(app);
        },
        .scroll_up, .scroll_down => {
            app.soundfont_param = p;
            const dir: i32 = if (ev.kind == .scroll_up) 1 else -1;
            adjustParam(app, dir * (if (ev.ctrl) @as(i32, 10) else 1));
        },
        else => {},
    }
}

/// Resets `app.soundfont_param` to its patch-init default. Shared by the
/// TUI's middle-click and the GUI knob's "Reset to default" menu item - see
/// `widgets.Knob`'s doc comment.
pub fn resetMouseParam(app: *App) void {
    var fresh = ws.dsp.SoundfontPlayer.init(app.allocator, app.session.project.sample_rate);
    defer fresh.deinit();
    const value = fresh.paramValue(app.soundfont_param) orelse return;
    history.recordParamSet(app, app.soundfont_track, app.soundfont_param);
    _ = app.session.engine.send(.{ .set_track_param_abs = .{ .track = app.soundfont_track, .id = app.soundfont_param, .value = value } });
}

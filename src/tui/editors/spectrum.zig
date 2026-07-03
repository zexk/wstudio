//! Spectrum/EQ view input: h/l pick a band, j/k (J/K coarse) nudge its gain,
//! b toggles bypass, esc restores the previous view and parks the analyzer.
//! The render half lives in views/spectrum.zig.

const ws = @import("wstudio");
const modal_mod = ws.input;
const dsp = ws.dsp.device;
const eq_mod = ws.dsp.eq;
const GraphicEq = ws.dsp.GraphicEq;
const App = @import("../app.zig").App;

pub fn switchToTrack(app: *App, track: u16) void {
    app.prev_view = app.view;
    app.view = .track_spectrum;
    app.eq_track = track;
    app.eq_cursor = 0;
    _ = app.session.engine.send(.{ .set_spectrum_active = .{ .source = .track, .track = track } });
}

pub fn switchToMaster(app: *App) void {
    app.prev_view = app.view;
    app.view = .master_spectrum;
    app.eq_cursor = 0;
    _ = app.session.engine.send(.{ .set_spectrum_active = .{ .source = .master, .track = 0 } });
}

pub fn handleKey(app: *App, key: modal_mod.Key) bool {
    switch (key) {
        .escape => {
            _ = app.session.engine.send(.{ .set_spectrum_active = .{ .source = .none, .track = 0 } });
            app.view = app.prev_view;
            return true;
        },
        .char => |c| switch (c) {
            'h' => { if (app.eq_cursor > 0) app.eq_cursor -= 1; },
            'l' => { if (app.eq_cursor < eq_mod.num_eq_bands - 1) app.eq_cursor += 1; },
            'j', 'J' => {
                if (app.view == .track_spectrum and app.eq_track < app.session.racks.items.len) {
                    const delta: f32 = if (c == 'J') -6.0 else -1.0;
                    setEqBand(app, app.eq_track, app.eq_cursor, currentEqGain(app, app.eq_track) + delta);
                }
            },
            'k', 'K' => {
                if (app.view == .track_spectrum and app.eq_track < app.session.racks.items.len) {
                    const delta: f32 = if (c == 'K') 6.0 else 1.0;
                    setEqBand(app, app.eq_track, app.eq_cursor, currentEqGain(app, app.eq_track) + delta);
                }
            },
            'b' => {
                if (app.view == .track_spectrum and app.eq_track < app.session.racks.items.len) {
                    if (app.session.racks.items[app.eq_track].fx.eq) |*eq| {
                        eq.bypass = !eq.bypass;
                        var buf: [6]dsp.Device = undefined;
                        app.session.engine.setTrackChain(app.eq_track, app.session.racks.items[app.eq_track].chain(&buf));
                    }
                }
            },
            else => return false,
        },
        else => return false,
    }
    return true;
}

fn currentEqGain(app: *App, track: u16) f32 {
    if (track < app.session.racks.items.len) {
        if (app.session.racks.items[track].fx.eq) |*e| return e.bands[app.eq_cursor].gain_db;
    }
    return 0.0;
}

pub fn setEqBand(app: *App, track: u16, band: usize, gain_db: f32) void {
    if (track >= app.session.racks.items.len) return;
    const rack = app.session.racks.items[track];
    if (rack.fx.eq == null) rack.fx.eq = GraphicEq.init(app.session.project.sample_rate);
    rack.fx.eq.?.setBand(band, gain_db);
    var buf: [6]dsp.Device = undefined;
    app.session.engine.setTrackChain(track, rack.chain(&buf));
}

//! Spectrum/FX rack input — shared by a track's view and the master bus.
//!
//! `Tab` cycles which of the four chain units (EQ, comp, delay, reverb) has
//! focus; `a` adds it with defaults or removes it; `h`/`l` pick a parameter
//! within the focused unit (EQ's are its 10 bands); `j`/`k` (`J`/`K` coarse)
//! nudge the selected parameter. `b` toggles EQ bypass — the only unit with
//! a bypass flag; comp/delay/reverb are simply present or absent.
//! `esc` restores the previous view and parks the analyzer.
//! The render half lives in views/spectrum.zig.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const dsp = ws.dsp.device;
const eq_mod = ws.dsp.eq;
const GraphicEq = ws.dsp.GraphicEq;
const Compressor = ws.dsp.Compressor;
const StereoDelay = ws.dsp.StereoDelay;
const Reverb = ws.dsp.Reverb;
const Fx = ws.Fx;
const App = @import("../app.zig").App;

/// Which chain stage the interactive editor is pointed at. Order matches
/// signal flow (comp → eq → delay → reverb, see `Fx.chain`) except EQ leads
/// here since it's the unit most players reach for first.
pub const FxUnit = enum { eq, comp, delay, reverb };

pub fn nextUnit(u: FxUnit) FxUnit {
    return switch (u) {
        .eq => .comp,
        .comp => .delay,
        .delay => .reverb,
        .reverb => .eq,
    };
}

pub fn unitLabel(u: FxUnit) []const u8 {
    return switch (u) {
        .eq => "EQ",
        .comp => "COMP",
        .delay => "DLY",
        .reverb => "REV",
    };
}

pub fn paramCount(u: FxUnit) usize {
    return switch (u) {
        .eq => eq_mod.num_eq_bands,
        .comp => 5,
        .delay => 3,
        .reverb => 3,
    };
}

/// Param name at `idx` within unit `u` — bounds match `paramCount`.
pub fn paramName(u: FxUnit, idx: usize) []const u8 {
    return switch (u) {
        .eq => "band",
        .comp => switch (idx) {
            0 => "thresh", 1 => "ratio", 2 => "attack", 3 => "release", 4 => "makeup",
            else => "?",
        },
        .delay => switch (idx) {
            0 => "time", 1 => "feedback", 2 => "mix",
            else => "?",
        },
        .reverb => switch (idx) {
            0 => "room", 1 => "damp", 2 => "mix",
            else => "?",
        },
    };
}

pub fn isPresent(fx: *const Fx, u: FxUnit) bool {
    return switch (u) {
        .eq => fx.eq != null,
        .comp => fx.comp != null,
        .delay => fx.delay != null,
        .reverb => fx.reverb != null,
    };
}

/// Current value of param `idx` in unit `u`, or 0 if the unit is absent —
/// callers gate on `isPresent` before trusting this for display.
pub fn getParam(fx: *const Fx, u: FxUnit, idx: usize) f32 {
    return switch (u) {
        .eq => if (fx.eq) |e| e.bands[idx].gain_db else 0,
        .comp => if (fx.comp) |c| switch (idx) {
            0 => c.threshold_db, 1 => c.ratio, 2 => c.attack_ms, 3 => c.release_ms, 4 => c.makeup_db,
            else => 0,
        } else 0,
        .delay => if (fx.delay) |d| switch (idx) {
            0 => @as(f32, @floatFromInt(d.delay_frames)) / @as(f32, @floatFromInt(d.sample_rate)),
            1 => d.feedback, 2 => d.mix,
            else => 0,
        } else 0,
        .reverb => if (fx.reverb) |r| switch (idx) {
            0 => r.room, 1 => r.damp, 2 => r.mix,
            else => 0,
        } else 0,
    };
}

/// Clamped absolute set of param `idx` in unit `u`; a no-op if the unit is
/// absent (callers add it first via `ensureUnit`/the `a` key).
pub fn setParam(fx: *Fx, u: FxUnit, idx: usize, value: f32) void {
    switch (u) {
        .eq => if (fx.eq) |*e| e.setBand(idx, value),
        .comp => if (fx.comp) |*c| switch (idx) {
            0 => c.threshold_db = std.math.clamp(value, -60.0, 0.0),
            1 => c.ratio = std.math.clamp(value, 1.0, 20.0),
            2 => c.attack_ms = std.math.clamp(value, 0.1, 500.0),
            3 => c.release_ms = std.math.clamp(value, 1.0, 2000.0),
            4 => c.makeup_db = std.math.clamp(value, -24.0, 24.0),
            else => {},
        },
        .delay => if (fx.delay) |*d| switch (idx) {
            0 => d.setTime(std.math.clamp(
                value, 0.01,
                @as(f32, @floatFromInt(d.lines[0].len)) / @as(f32, @floatFromInt(d.sample_rate)),
            )),
            1 => d.feedback = std.math.clamp(value, 0.0, 0.95),
            2 => d.mix = std.math.clamp(value, 0.0, 1.0),
            else => {},
        },
        .reverb => if (fx.reverb) |*r| switch (idx) {
            0 => r.room = std.math.clamp(value, 0.0, 0.98),
            1 => r.damp = std.math.clamp(value, 0.0, 1.0),
            2 => r.mix = std.math.clamp(value, 0.0, 1.0),
            else => {},
        },
    }
}

/// Nudge step for `j`/`k` (`coarse` = `J`/`K`) — sized per param so a single
/// press is a musically useful move (e.g. 1dB fine / 6dB coarse for EQ and
/// comp threshold, fractions for the 0..1-ish delay/reverb knobs).
fn paramStep(u: FxUnit, idx: usize, coarse: bool) f32 {
    return switch (u) {
        .eq => if (coarse) @as(f32, 6.0) else 1.0,
        .comp => switch (idx) {
            0 => if (coarse) @as(f32, 6.0) else 1.0,
            1 => if (coarse) @as(f32, 2.0) else 0.5,
            2 => if (coarse) @as(f32, 50.0) else 5.0,
            3 => if (coarse) @as(f32, 200.0) else 20.0,
            4 => if (coarse) @as(f32, 3.0) else 0.5,
            else => 1.0,
        },
        .delay => switch (idx) {
            0 => if (coarse) @as(f32, 0.1) else 0.01,
            else => if (coarse) @as(f32, 0.2) else 0.05,
        },
        .reverb => switch (idx) {
            0 => if (coarse) @as(f32, 0.1) else 0.02,
            else => if (coarse) @as(f32, 0.2) else 0.05,
        },
    };
}

/// The Fx chain currently in view — a track's rack, or the master bus.
/// Null only if `app.eq_track` fell out of range (e.g. its track was
/// deleted from under an open track_spectrum view).
pub fn fxPtr(app: *App, is_track: bool) ?*Fx {
    if (is_track) {
        if (app.eq_track >= app.session.racks.items.len) return null;
        return &app.session.racks.items[app.eq_track].fx;
    }
    return &app.session.master_fx;
}

fn syncChain(app: *App, is_track: bool) void {
    if (is_track) {
        if (app.eq_track >= app.session.racks.items.len) return;
        const rack = app.session.racks.items[app.eq_track];
        var buf: [6]dsp.Device = undefined;
        app.session.engine.setTrackChain(app.eq_track, rack.chain(&buf));
    } else {
        app.session.syncMasterChain();
    }
}

/// Adds unit `u` with defaults if absent; a no-op if already present.
/// Returns false (and sets a status message) only on allocation failure —
/// delay/reverb own heap-allocated lines, eq/comp don't.
fn ensureUnit(app: *App, fx: *Fx, u: FxUnit) bool {
    const sr = app.session.project.sample_rate;
    switch (u) {
        .eq => { if (fx.eq == null) fx.eq = GraphicEq.init(sr); },
        .comp => { if (fx.comp == null) fx.comp = Compressor.init(sr); },
        .delay => {
            if (fx.delay != null) return true;
            fx.delay = StereoDelay.init(app.session.allocator, sr, 2.0) catch {
                app.setStatus("delay: out of memory", .{});
                return false;
            };
        },
        .reverb => {
            if (fx.reverb != null) return true;
            fx.reverb = Reverb.init(app.session.allocator, sr) catch {
                app.setStatus("reverb: out of memory", .{});
                return false;
            };
        },
    }
    return true;
}

fn removeUnit(app: *App, fx: *Fx, u: FxUnit) void {
    switch (u) {
        .eq => fx.eq = null,
        .comp => fx.comp = null,
        .delay => if (fx.delay) |*d| { d.deinit(app.session.allocator); fx.delay = null; },
        .reverb => if (fx.reverb) |*r| { r.deinit(app.session.allocator); fx.reverb = null; },
    }
}

fn toggleUnit(app: *App, is_track: bool) void {
    const fx = fxPtr(app, is_track) orelse return;
    const u = app.fx_focus;
    if (isPresent(fx, u)) {
        removeUnit(app, fx, u);
        app.setStatus("{s} removed", .{unitLabel(u)});
    } else if (ensureUnit(app, fx, u)) {
        app.setStatus("{s} added", .{unitLabel(u)});
    } else {
        return; // ensureUnit already reported why
    }
    app.fx_param = 0;
    app.dirty = true;
    syncChain(app, is_track);
}

fn nudge(app: *App, is_track: bool, key: u8) void {
    const fx = fxPtr(app, is_track) orelse return;
    if (!isPresent(fx, app.fx_focus)) return;
    const dir: f32 = if (key == 'j' or key == 'J') -1.0 else 1.0;
    const coarse = (key == 'J' or key == 'K');
    const cnt: f32 = @floatFromInt(app.takeCount());
    const cur = getParam(fx, app.fx_focus, app.fx_param);
    setParam(fx, app.fx_focus, app.fx_param, cur + dir * cnt * paramStep(app.fx_focus, app.fx_param, coarse));
    app.dirty = true;
    syncChain(app, is_track);
}

fn toggleEqBypass(app: *App, is_track: bool) void {
    const fx = fxPtr(app, is_track) orelse return;
    if (fx.eq) |*e| {
        e.bypass = !e.bypass;
        app.dirty = true;
        syncChain(app, is_track);
    }
}

pub fn switchToTrack(app: *App, track: u16) void {
    app.prev_view = app.view;
    app.view = .track_spectrum;
    app.eq_track = track;
    app.fx_focus = .eq;
    app.fx_param = 0;
    _ = app.session.engine.send(.{ .set_spectrum_active = .{ .source = .track, .track = track } });
}

pub fn switchToMaster(app: *App) void {
    app.prev_view = app.view;
    app.view = .master_spectrum;
    app.fx_focus = .eq;
    app.fx_param = 0;
    _ = app.session.engine.send(.{ .set_spectrum_active = .{ .source = .master, .track = 0 } });
}

pub fn handleKey(app: *App, key: modal_mod.Key) bool {
    const is_track = app.view == .track_spectrum;
    switch (key) {
        .escape => {
            _ = app.session.engine.send(.{ .set_spectrum_active = .{ .source = .none, .track = 0 } });
            app.view = app.prev_view;
            return true;
        },
        .tab => {
            app.fx_focus = nextUnit(app.fx_focus);
            app.fx_param = 0;
            return true;
        },
        .char => |c| switch (c) {
            'a' => { toggleUnit(app, is_track); return true; },
            // Param picks take a vim count prefix (3l, 4h, …). EQ clamps at
            // its band ends (unchanged from before); the 3-5 param units
            // wrap, which reads more naturally for such a short list.
            'h' => {
                const n = paramCount(app.fx_focus);
                const cnt: usize = @intCast(app.takeCount());
                app.fx_param = if (app.fx_focus == .eq)
                    app.fx_param -| cnt
                else
                    (app.fx_param + n - (cnt % n)) % n;
                return true;
            },
            'l' => {
                const n = paramCount(app.fx_focus);
                const cnt: usize = @intCast(app.takeCount());
                app.fx_param = if (app.fx_focus == .eq)
                    @min(app.fx_param + cnt, n - 1)
                else
                    (app.fx_param + cnt) % n;
                return true;
            },
            'j', 'J', 'k', 'K' => { nudge(app, is_track, c); return true; },
            'b' => { toggleEqBypass(app, is_track); return true; },
            else => return false,
        },
        else => return false,
    }
}

/// `:eq <track> [<band> <db>]` support — same shape kept for backward
/// compatibility with the command-line path; auto-creates the EQ (matching
/// its long-standing behaviour) rather than requiring `a` first.
pub fn setEqBand(app: *App, track: u16, band: usize, gain_db: f32) void {
    if (track >= app.session.racks.items.len) return;
    const rack = app.session.racks.items[track];
    if (rack.fx.eq == null) rack.fx.eq = GraphicEq.init(app.session.project.sample_rate);
    rack.fx.eq.?.setBand(band, gain_db);
    app.dirty = true;
    var buf: [6]dsp.Device = undefined;
    app.session.engine.setTrackChain(track, rack.chain(&buf));
}

/// Same as `setEqBand` but for the master bus — no track index, and pushes
/// the change through `Session.syncMasterChain` instead of `setTrackChain`.
pub fn setMasterEqBand(app: *App, band: usize, gain_db: f32) void {
    if (app.session.master_fx.eq == null)
        app.session.master_fx.eq = GraphicEq.init(app.session.project.sample_rate);
    app.session.master_fx.eq.?.setBand(band, gain_db);
    app.dirty = true;
    app.session.syncMasterChain();
}

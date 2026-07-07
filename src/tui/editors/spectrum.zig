//! FX rack input — shared by a track's view and the master bus.
//!
//! The chain strip is the view's centrepiece: four slots in signal-flow
//! order (comp → eq → delay → reverb), the focused slot's editor filling
//! the body below. The spectrum analyzer belongs to the EQ slot's editor
//! and only runs while that slot has focus.
//!
//! `Tab`/`L` and `H` walk slot focus along the chain; `a` adds the focused
//! unit with defaults or removes it; `h`/`l` pick a parameter within the
//! focused unit (EQ's are its 10 bands); `j`/`k` (`J`/`K` coarse) nudge the
//! selected parameter. `b` toggles EQ bypass — the only unit with a bypass
//! flag; comp/delay/reverb are simply present or absent.
//! `esc` restores the previous view and parks the analyzer.
//! The render half lives in views/spectrum.zig.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const dsp = ws.dsp.device;
const eq_mod = ws.dsp.eq;
const style = @import("../style.zig");
const GraphicEq = ws.dsp.GraphicEq;
const Compressor = ws.dsp.Compressor;
const StereoDelay = ws.dsp.StereoDelay;
const Reverb = ws.dsp.Reverb;
const Fx = ws.Fx;
const App = @import("../app.zig").App;

/// Which chain slot the interactive editor is pointed at. Order matches
/// signal flow (comp → eq → delay → reverb, see `Fx.chain`) so walking
/// focus with H/L/tab moves along the chain the audio actually takes.
/// Entering the view still lands on .eq — the slot most players reach
/// for first, and the one whose editor shows the spectrum analyzer.
pub const FxUnit = enum { comp, eq, delay, reverb };

pub fn nextUnit(u: FxUnit) FxUnit {
    return switch (u) {
        .comp => .eq,
        .eq => .delay,
        .delay => .reverb,
        .reverb => .comp,
    };
}

pub fn prevUnit(u: FxUnit) FxUnit {
    return switch (u) {
        .comp => .reverb,
        .eq => .comp,
        .delay => .eq,
        .reverb => .delay,
    };
}

pub fn unitLabel(u: FxUnit) []const u8 {
    return switch (u) {
        .comp => "COMP",
        .eq => "EQ",
        .delay => "DELAY",
        .reverb => "REVERB",
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

/// [min, max] of param `idx` in unit `u` — the same bounds `setParam`
/// clamps to, exported so the view can draw each param as a filled bar
/// (barRow wants a 0..1-ish normalised value).
pub fn paramRange(u: FxUnit, idx: usize) [2]f32 {
    return switch (u) {
        .eq => .{ -18.0, 18.0 },
        .comp => switch (idx) {
            0 => .{ -60.0, 0.0 },
            1 => .{ 1.0, 20.0 },
            2 => .{ 0.1, 500.0 },
            3 => .{ 1.0, 2000.0 },
            4 => .{ -24.0, 24.0 },
            else => .{ 0.0, 1.0 },
        },
        .delay => switch (idx) {
            0 => .{ 0.01, 2.0 }, // matches the 2.0s line StereoDelay.init allocates
            1 => .{ 0.0, 0.95 },
            else => .{ 0.0, 1.0 },
        },
        .reverb => switch (idx) {
            0 => .{ 0.0, 0.98 },
            else => .{ 0.0, 1.0 },
        },
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

/// The spectrum analyzer belongs to the EQ slot's editor: run it only while
/// that slot has focus, park it otherwise (and on leaving the view) so the
/// engine skips FFT work nobody is looking at.
fn syncAnalyzer(app: *App, is_track: bool) void {
    if (app.fx_focus == .eq) {
        _ = app.session.engine.send(.{ .set_spectrum_active = .{
            .source = if (is_track) .track else .master,
            .track = if (is_track) app.eq_track else 0,
        } });
    } else {
        _ = app.session.engine.send(.{ .set_spectrum_active = .{ .source = .none, .track = 0 } });
    }
}

fn setFocus(app: *App, is_track: bool, u: FxUnit) void {
    app.fx_focus = u;
    app.fx_param = 0;
    syncAnalyzer(app, is_track);
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
        .tab => { setFocus(app, is_track, nextUnit(app.fx_focus)); return true; },
        .char => |c| switch (c) {
            'H' => { setFocus(app, is_track, prevUnit(app.fx_focus)); return true; },
            'L' => { setFocus(app, is_track, nextUnit(app.fx_focus)); return true; },
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

// Row layout mirrors views/spectrum.zig's drawFxView exactly: title, the
// 3-row chain strip, a key-hint row, the focused slot's section divider,
// then its editor body. For the EQ slot the body is `visual_rows` spectrum
// rows + an Hz-label row + the band rows; for the other slots it's one
// barRow per param (or a single hint row while the unit is absent).

// Chain strip geometry, middle row: " IN ─▶ " gutter, then four 11-wide
// slot boxes ("┃ COMP   ●┃") joined by 3-wide "─▶ " arrows — slot i starts
// at column strip_x0 + i*(strip_box_w + strip_gap_w).
pub const strip_x0: usize = 7;
pub const strip_box_w: usize = 11;
pub const strip_gap_w: usize = 3;
pub const strip_rows_start: usize = 1; // first row after the title
pub const strip_rows_end: usize = 3;   // inclusive
pub const body_row0: usize = 6;        // title + strip(3) + hint + section

/// Short terminals can't fit the boxed strip + hint + the biggest editor
/// body (comp's 5 rows) inside the rows-5 content budget, so below this
/// the strip collapses to its middle row and the hint line is dropped —
/// keeping the app header pinned down to 13 rows, same floor as before
/// the rack revamp. Uniform per-height (not per-focus) so the layout
/// doesn't jump while tabbing between slots.
pub fn compactLayout(rows: usize) bool {
    return rows < 16;
}

/// First body row below the title/strip/hint/section prelude.
pub fn bodyRow0(compact: bool) usize {
    return if (compact) 3 else body_row0;
}

/// Which chain slot a click at column `x` on the strip rows lands in, if any.
fn slotAt(x: usize) ?FxUnit {
    inline for (0..4) |i| {
        const x0 = strip_x0 + i * (strip_box_w + strip_gap_w);
        if (x >= x0 and x < x0 + strip_box_w) return @enumFromInt(i);
    }
    return null;
}

/// EQ-body band-row count: bar + value + freq rows when present, one hint
/// row when absent. The view sizes `visual_rows` off the same number.
pub fn eqBandRows(fx: *const ws.Fx) usize {
    return if (fx.eq != null) 3 else 1;
}

// EQ band row: a 3-char gutter, then a 5-char cell per band (bracket/glyph/
// bracket on the bar row; a 5-wide centered field on the value/freq rows) —
// see drawFxView's EQ branch.
const eq_gutter: usize = 3;
const eq_band_w: usize = 5;

fn eqBandAt(x: usize) ?usize {
    if (x < eq_gutter) return null;
    const col = (x - eq_gutter) / eq_band_w;
    if (col >= eq_mod.num_eq_bands) return null;
    return col;
}

/// Nudge the current param one wheel-notch (**ctrl** = coarse), reusing the
/// same `nudge` the keyboard's j/J/k/K use — scroll up = increase (k/K),
/// scroll down = decrease (j/J).
fn nudgeMouse(app: *App, is_track: bool, ev: modal_mod.MouseEvent) void {
    const up = ev.kind == .scroll_up;
    const key: u8 = if (up) (if (ev.ctrl) @as(u8, 'K') else 'k') else (if (ev.ctrl) @as(u8, 'J') else 'j');
    nudge(app, is_track, key);
}

/// Click a chain-strip slot box to focus it; click an EQ band or a
/// comp/delay/reverb param row to select it; scroll over either nudges it
/// (**ctrl**+scroll = coarse).
pub fn handleMouse(app: *App, ev: modal_mod.MouseEvent, row: usize, cols: u16, view_rows: usize) void {
    _ = cols; // slot/band/param columns here are fixed-width, not terminal-width-dependent
    const is_track = app.view == .track_spectrum;
    const fx = fxPtr(app, is_track) orelse return;
    const compact = compactLayout(view_rows);

    if (row >= strip_rows_start and row <= (if (compact) strip_rows_start else strip_rows_end)) {
        if (ev.kind == .press) {
            const u = slotAt(ev.x) orelse return;
            setFocus(app, is_track, u);
        }
        return;
    }
    const body0 = bodyRow0(compact);
    if (row < body0) return; // title / hint / section rows — not interactive
    const rel = row - body0;

    if (app.fx_focus == .eq) {
        if (fx.eq == null) return;
        // Same sizing as drawFxView: spectrum graph, then the Hz-label row,
        // then the three band rows — only the band rows are interactive.
        const bands = eqBandRows(fx);
        const visual_rows: usize = @min(style.spectrum_rows, view_rows -| ((if (compact) @as(usize, 9) else 12) + bands));
        const band_row0 = visual_rows + 1;
        if (rel < band_row0 or rel >= band_row0 + bands) return;
        const band = eqBandAt(ev.x) orelse return;
        switch (ev.kind) {
            .press => app.fx_param = band,
            .scroll_up, .scroll_down => {
                app.fx_param = band;
                nudgeMouse(app, is_track, ev);
            },
            else => {},
        }
        return;
    }

    if (!isPresent(fx, app.fx_focus)) return;
    if (rel >= paramCount(app.fx_focus)) return;
    switch (ev.kind) {
        .press => app.fx_param = rel,
        .scroll_up, .scroll_down => {
            app.fx_param = rel;
            nudgeMouse(app, is_track, ev);
        },
        else => {},
    }
}

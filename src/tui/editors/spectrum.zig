//! FX chain input — shared by a track's view and the master bus.
//!
//! The chain strip is the view's centrepiece: the units the user has
//! inserted, drawn in signal-flow order, with a trailing "+" box while
//! there's room for more. Chains start empty; `a` opens the FX picker
//! (same idea as the instrument picker) and inserts the chosen unit after
//! the focused slot, so the user decides what runs and in what order —
//! duplicates included. The spectrum analyzer belongs to an EQ unit's
//! editor and only runs while one has focus.
//!
//! `Tab`/`]`/`[` walk slot focus along the chain (the boxes it moves
//! between are drawn left-to-right onscreen); `a` inserts via the picker;
//! `x` removes the focused unit; `<`/`>` move it along the chain; `b`
//! toggles its bypass (kept in the chain, skipped by the audio path);
//! `j`/`k` pick a parameter within the focused unit — the vertical axis,
//! matching the param list's on-screen layout (EQ's are its 10 bands);
//! `h`/`l` (`H`/`L` coarse) nudge the selected parameter's value along the
//! horizontal axis, matching its on-screen bar.
//! `esc` restores the previous view and parks the analyzer.
//! The render half lives in views/spectrum.zig.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const dsp = ws.dsp.device;
const eq_mod = ws.dsp.eq;
const style = @import("../style.zig");
const chorus_mod = ws.dsp.chorus;
const Fx = ws.Fx;
const FxKind = ws.FxKind;
const FxUnit = ws.FxUnit;
const FxPayload = ws.FxPayload;
const App = @import("../app.zig").App;

/// The insertable kinds in picker display order (signal-flow-ish: dynamics,
/// tone, character, modulation, time). Parallel to `picker_menu` in
/// views/picker.zig.
pub const picker_kinds = [_]FxKind{
    .gate, .comp, .eq, .sat, .crush, .chorus, .phaser, .delay, .reverb,
};

pub fn unitLabel(k: FxKind) []const u8 {
    return switch (k) {
        .gate => "GATE",
        .comp => "COMP",
        .eq => "EQ",
        .sat => "SAT",
        .crush => "CRUSH",
        .chorus => "CHORUS",
        .phaser => "PHASER",
        .delay => "DELAY",
        .reverb => "REVERB",
    };
}

/// <=4-char label for the chain strip's slot boxes; nine boxes have to
/// share an 80-col row, so each gets a 7-wide box (see the strip geometry
/// constants below).
pub fn stripLabel(k: FxKind) []const u8 {
    return switch (k) {
        .gate => "GATE",
        .comp => "COMP",
        .eq => "EQ",
        .sat => "SAT",
        .crush => "CRSH",
        .chorus => "CHOR",
        .phaser => "PHAS",
        .delay => "DLY",
        .reverb => "VERB",
    };
}

pub fn paramCount(k: FxKind) usize {
    return switch (k) {
        .eq => eq_mod.num_eq_bands,
        .comp => 5,
        .phaser => 4,
        .gate, .sat, .crush, .chorus, .delay, .reverb => 3,
    };
}

/// Param name at `idx` within a unit of kind `k` — bounds match `paramCount`.
pub fn paramName(k: FxKind, idx: usize) []const u8 {
    return switch (k) {
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
        .gate => switch (idx) {
            0 => "thresh", 1 => "attack", 2 => "release",
            else => "?",
        },
        .sat => switch (idx) {
            0 => "drive", 1 => "output", 2 => "mix",
            else => "?",
        },
        .crush => switch (idx) {
            0 => "bits", 1 => "downsmp", 2 => "mix",
            else => "?",
        },
        .chorus => switch (idx) {
            0 => "rate", 1 => "depth", 2 => "mix",
            else => "?",
        },
        .phaser => switch (idx) {
            0 => "rate", 1 => "depth", 2 => "feedback", 3 => "mix",
            else => "?",
        },
    };
}

/// Current value of param `idx` in `p` — bounds match `paramCount`.
pub fn getParam(p: *const FxPayload, idx: usize) f32 {
    return switch (p.*) {
        .eq => |*e| e.bands[idx].gain_db,
        .comp => |*c| switch (idx) {
            0 => c.threshold_db, 1 => c.ratio, 2 => c.attack_ms, 3 => c.release_ms, 4 => c.makeup_db,
            else => 0,
        },
        .delay => |*d| switch (idx) {
            0 => @as(f32, @floatFromInt(d.delay_frames)) / @as(f32, @floatFromInt(d.sample_rate)),
            1 => d.feedback, 2 => d.mix,
            else => 0,
        },
        .reverb => |*r| switch (idx) {
            0 => r.room, 1 => r.damp, 2 => r.mix,
            else => 0,
        },
        .gate => |*g| switch (idx) {
            0 => g.threshold_db, 1 => g.attack_ms, 2 => g.release_ms,
            else => 0,
        },
        .sat => |*s| switch (idx) {
            0 => s.drive_db, 1 => s.out_db, 2 => s.mix,
            else => 0,
        },
        .crush => |*c| switch (idx) {
            0 => c.bits, 1 => c.downsample, 2 => c.mix,
            else => 0,
        },
        .chorus => |*c| switch (idx) {
            0 => c.rate_hz, 1 => c.depth_ms, 2 => c.mix,
            else => 0,
        },
        .phaser => |*p2| switch (idx) {
            0 => p2.rate_hz, 1 => p2.depth, 2 => p2.feedback, 3 => p2.mix,
            else => 0,
        },
    };
}

/// [min, max] of param `idx` in a unit of kind `k` — the same bounds
/// `setParam` clamps to, exported so the view can draw each param as a
/// filled bar (barRow wants a 0..1-ish normalised value).
pub fn paramRange(k: FxKind, idx: usize) [2]f32 {
    return switch (k) {
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
        .gate => switch (idx) {
            0 => .{ -80.0, 0.0 },
            1 => .{ 0.1, 50.0 },
            2 => .{ 5.0, 1000.0 },
            else => .{ 0.0, 1.0 },
        },
        .sat => switch (idx) {
            0 => .{ 0.0, 36.0 },
            1 => .{ -24.0, 24.0 },
            else => .{ 0.0, 1.0 },
        },
        .crush => switch (idx) {
            0 => .{ 1.0, 16.0 },
            1 => .{ 1.0, 32.0 },
            else => .{ 0.0, 1.0 },
        },
        .chorus => switch (idx) {
            0 => .{ 0.05, 5.0 },
            1 => .{ 0.0, chorus_mod.max_depth_ms },
            else => .{ 0.0, 1.0 },
        },
        .phaser => switch (idx) {
            0 => .{ 0.05, 5.0 },
            2 => .{ 0.0, 0.9 },
            else => .{ 0.0, 1.0 },
        },
    };
}

/// Clamped absolute set of param `idx` in `p` — bounds match `paramRange`.
pub fn setParam(p: *FxPayload, idx: usize, value: f32) void {
    switch (p.*) {
        .eq => |*e| e.setBand(idx, value),
        .comp => |*c| switch (idx) {
            0 => c.threshold_db = std.math.clamp(value, -60.0, 0.0),
            1 => c.ratio = std.math.clamp(value, 1.0, 20.0),
            2 => c.attack_ms = std.math.clamp(value, 0.1, 500.0),
            3 => c.release_ms = std.math.clamp(value, 1.0, 2000.0),
            4 => c.makeup_db = std.math.clamp(value, -24.0, 24.0),
            else => {},
        },
        .delay => |*d| switch (idx) {
            0 => d.setTime(std.math.clamp(
                value, 0.01,
                @as(f32, @floatFromInt(d.lines[0].len)) / @as(f32, @floatFromInt(d.sample_rate)),
            )),
            1 => d.feedback = std.math.clamp(value, 0.0, 0.95),
            2 => d.mix = std.math.clamp(value, 0.0, 1.0),
            else => {},
        },
        .reverb => |*r| switch (idx) {
            0 => r.room = std.math.clamp(value, 0.0, 0.98),
            1 => r.damp = std.math.clamp(value, 0.0, 1.0),
            2 => r.mix = std.math.clamp(value, 0.0, 1.0),
            else => {},
        },
        .gate => |*g| switch (idx) {
            0 => g.threshold_db = std.math.clamp(value, -80.0, 0.0),
            1 => g.attack_ms = std.math.clamp(value, 0.1, 50.0),
            2 => g.release_ms = std.math.clamp(value, 5.0, 1000.0),
            else => {},
        },
        .sat => |*s| switch (idx) {
            0 => s.drive_db = std.math.clamp(value, 0.0, 36.0),
            1 => s.out_db = std.math.clamp(value, -24.0, 24.0),
            2 => s.mix = std.math.clamp(value, 0.0, 1.0),
            else => {},
        },
        .crush => |*c| switch (idx) {
            0 => c.bits = std.math.clamp(@round(value), 1.0, 16.0),
            1 => c.downsample = std.math.clamp(@round(value), 1.0, 32.0),
            2 => c.mix = std.math.clamp(value, 0.0, 1.0),
            else => {},
        },
        .chorus => |*c| switch (idx) {
            0 => c.rate_hz = std.math.clamp(value, 0.05, 5.0),
            1 => c.depth_ms = std.math.clamp(value, 0.0, chorus_mod.max_depth_ms),
            2 => c.mix = std.math.clamp(value, 0.0, 1.0),
            else => {},
        },
        .phaser => |*p2| switch (idx) {
            0 => p2.rate_hz = std.math.clamp(value, 0.05, 5.0),
            1 => p2.depth = std.math.clamp(value, 0.0, 1.0),
            2 => p2.feedback = std.math.clamp(value, 0.0, 0.9),
            3 => p2.mix = std.math.clamp(value, 0.0, 1.0),
            else => {},
        },
    }
}

/// Nudge step for `j`/`k` (`coarse` = `J`/`K`) — sized per param so a single
/// press is a musically useful move (e.g. 1dB fine / 6dB coarse for EQ and
/// comp threshold, fractions for the 0..1-ish delay/reverb knobs).
fn paramStep(k: FxKind, idx: usize, coarse: bool) f32 {
    return switch (k) {
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
        .gate => switch (idx) {
            0 => if (coarse) @as(f32, 6.0) else 1.0,
            1 => if (coarse) @as(f32, 5.0) else 0.5,
            2 => if (coarse) @as(f32, 100.0) else 10.0,
            else => 1.0,
        },
        .sat => switch (idx) {
            0 => if (coarse) @as(f32, 6.0) else 1.0,
            1 => if (coarse) @as(f32, 3.0) else 0.5,
            else => if (coarse) @as(f32, 0.2) else 0.05,
        },
        .crush => switch (idx) {
            0, 1 => if (coarse) @as(f32, 4.0) else 1.0,
            else => if (coarse) @as(f32, 0.2) else 0.05,
        },
        .chorus => switch (idx) {
            0 => if (coarse) @as(f32, 0.5) else 0.05,
            1 => if (coarse) @as(f32, 2.0) else 0.5,
            else => if (coarse) @as(f32, 0.2) else 0.05,
        },
        .phaser => switch (idx) {
            0 => if (coarse) @as(f32, 0.5) else 0.05,
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

/// The unit under `app.fx_focus`, or null while the chain is empty (the
/// focus index is clamped by every mutation, so out-of-range means empty).
pub fn focusedUnit(app: *App, fx: *const Fx) ?*FxUnit {
    if (app.fx_focus >= fx.units.items.len) return null;
    return fx.units.items[app.fx_focus];
}

fn syncChain(app: *App, is_track: bool) void {
    if (is_track) {
        if (app.eq_track >= app.session.racks.items.len) return;
        const rack = app.session.racks.items[app.eq_track];
        var buf: [ws.Rack.chain_cap]dsp.Device = undefined;
        app.session.engine.setTrackChain(app.eq_track, rack.chain(&buf));
    } else {
        app.session.syncMasterChain();
    }
}

/// The spectrum analyzer belongs to an EQ unit's editor: run it only while
/// one has focus, park it otherwise (and on leaving the view) so the engine
/// skips FFT work nobody is looking at.
fn syncAnalyzer(app: *App, is_track: bool) void {
    const focused_eq = if (fxPtr(app, is_track)) |fx| blk: {
        const u = focusedUnit(app, fx) orelse break :blk false;
        break :blk u.kind() == .eq;
    } else false;
    if (focused_eq) {
        _ = app.session.engine.send(.{ .set_spectrum_active = .{
            .source = if (is_track) .track else .master,
            .track = if (is_track) app.eq_track else 0,
        } });
    } else {
        _ = app.session.engine.send(.{ .set_spectrum_active = .{ .source = .none, .track = 0 } });
    }
}

fn setFocus(app: *App, is_track: bool, idx: usize) void {
    app.fx_focus = idx;
    app.fx_param = 0;
    syncAnalyzer(app, is_track);
}

pub fn switchToTrack(app: *App, track: u16) void {
    app.prev_view = app.view;
    app.view = .track_spectrum;
    app.eq_track = track;
    setFocus(app, true, 0);
}

pub fn switchToMaster(app: *App) void {
    app.prev_view = app.view;
    app.view = .master_spectrum;
    setFocus(app, false, 0);
}

/// Open the FX picker for the chain in view. Inserting lands after the
/// focused slot (at the front while the chain is empty). Parks the analyzer
/// — the picker replaces the whole view, so nobody is watching it.
fn openPicker(app: *App, is_track: bool) void {
    const fx = fxPtr(app, is_track) orelse return;
    if (fx.units.items.len >= Fx.max_units) {
        app.setStatus("chain full ({d} units)", .{Fx.max_units});
        return;
    }
    _ = app.session.engine.send(.{ .set_spectrum_active = .{ .source = .none, .track = 0 } });
    app.fx_picker_return = app.view;
    app.fx_picker_cursor = 0;
    app.view = .fx_picker;
}

/// Picker accepted: back to the chain view, insert after the focused slot,
/// focus the new unit. Called by App.handleFxPickerKey.
pub fn insertFromPicker(app: *App, k: FxKind) void {
    const is_track = app.fx_picker_return == .track_spectrum;
    app.view = app.fx_picker_return;
    const fx = fxPtr(app, is_track) orelse return;
    const pos = if (fx.units.items.len == 0) 0 else @min(app.fx_focus + 1, fx.units.items.len);
    _ = fx.insert(app.session.allocator, pos, k, app.session.project.sample_rate) catch |err| {
        switch (err) {
            error.ChainFull => app.setStatus("chain full ({d} units)", .{Fx.max_units}),
            error.OutOfMemory => app.setStatus("{s}: out of memory", .{unitLabel(k)}),
        }
        syncAnalyzer(app, is_track);
        return;
    };
    setFocus(app, is_track, pos);
    app.dirty = true;
    syncChain(app, is_track);
    app.setStatus("{s} inserted", .{unitLabel(k)});
}

/// Picker dismissed: back to the chain view, nothing inserted.
pub fn cancelPicker(app: *App) void {
    app.view = app.fx_picker_return;
    syncAnalyzer(app, app.view == .track_spectrum);
}

fn removeFocused(app: *App, is_track: bool) void {
    const fx = fxPtr(app, is_track) orelse return;
    if (app.fx_focus >= fx.units.items.len) return;
    // Unlink and push the shortened chain to the audio thread *before*
    // freeing the unit, so a delay/reverb line can't be torn down while a
    // freshly-fetched chain still points at it.
    const unit = fx.units.orderedRemove(app.fx_focus);
    syncChain(app, is_track);
    const label = unitLabel(unit.kind());
    unit.payload.deinit(app.session.allocator);
    app.session.allocator.destroy(unit);
    if (app.fx_focus > 0 and app.fx_focus >= fx.units.items.len) app.fx_focus -= 1;
    app.fx_param = 0;
    app.dirty = true;
    syncAnalyzer(app, is_track);
    app.setStatus("{s} removed", .{label});
}

/// Move the focused unit one slot along the chain; focus follows it.
fn moveFocused(app: *App, is_track: bool, dir: i2) void {
    const fx = fxPtr(app, is_track) orelse return;
    if (focusedUnit(app, fx) == null) return;
    const other = if (dir < 0) app.fx_focus -% 1 else app.fx_focus + 1;
    if (other >= fx.units.items.len) return; // already at that end (wraps on 0-%1)
    fx.swap(app.fx_focus, other);
    app.fx_focus = other;
    app.dirty = true;
    syncChain(app, is_track);
}

fn toggleBypass(app: *App, is_track: bool) void {
    const fx = fxPtr(app, is_track) orelse return;
    const u = focusedUnit(app, fx) orelse return;
    u.bypassed = !u.bypassed;
    app.dirty = true;
    syncChain(app, is_track);
    app.setStatus("{s} {s}", .{ unitLabel(u.kind()), if (u.bypassed) "bypassed" else "active" });
}

fn nudge(app: *App, is_track: bool, key: u8) void {
    const fx = fxPtr(app, is_track) orelse return;
    const u = focusedUnit(app, fx) orelse return;
    const dir: f32 = if (key == 'h' or key == 'H') -1.0 else 1.0;
    const coarse = (key == 'H' or key == 'L');
    const cnt: f32 = @floatFromInt(app.takeCount());
    const cur = getParam(&u.payload, app.fx_param);
    setParam(&u.payload, app.fx_param, cur + dir * cnt * paramStep(u.kind(), app.fx_param, coarse));
    app.dirty = true;
    syncChain(app, is_track);
}

pub fn handleKey(app: *App, key: modal_mod.Key) bool {
    const is_track = app.view == .track_spectrum;
    const len = if (fxPtr(app, is_track)) |fx| fx.units.items.len else 0;
    switch (key) {
        .escape => {
            _ = app.session.engine.send(.{ .set_spectrum_active = .{ .source = .none, .track = 0 } });
            app.view = app.prev_view;
            return true;
        },
        .tab => {
            if (len > 0) setFocus(app, is_track, (app.fx_focus + 1) % len);
            return true;
        },
        .char => |c| switch (c) {
            '[' => {
                if (len > 0) setFocus(app, is_track, (app.fx_focus + len - 1) % len);
                return true;
            },
            ']' => {
                if (len > 0) setFocus(app, is_track, (app.fx_focus + 1) % len);
                return true;
            },
            'a' => { openPicker(app, is_track); return true; },
            'x' => { removeFocused(app, is_track); return true; },
            '<' => { moveFocused(app, is_track, -1); return true; },
            '>' => { moveFocused(app, is_track, 1); return true; },
            'b' => { toggleBypass(app, is_track); return true; },
            // Param picks take a vim count prefix (3k, 4j, …). EQ clamps at
            // its band ends (unchanged from before); the 3-5 param units
            // wrap, which reads more naturally for such a short list.
            'k' => {
                const fx = fxPtr(app, is_track) orelse return true;
                const u = focusedUnit(app, fx) orelse return true;
                const n = paramCount(u.kind());
                const cnt: usize = @intCast(app.takeCount());
                app.fx_param = if (u.kind() == .eq)
                    app.fx_param -| cnt
                else
                    (app.fx_param + n - (cnt % n)) % n;
                return true;
            },
            'j' => {
                const fx = fxPtr(app, is_track) orelse return true;
                const u = focusedUnit(app, fx) orelse return true;
                const n = paramCount(u.kind());
                const cnt: usize = @intCast(app.takeCount());
                app.fx_param = if (u.kind() == .eq)
                    @min(app.fx_param + cnt, n - 1)
                else
                    (app.fx_param + cnt) % n;
                return true;
            },
            'h', 'H', 'l', 'L' => { nudge(app, is_track, c); return true; },
            else => return false,
        },
        else => return false,
    }
}

/// `:eq <track> [<band> <db>]` support — same shape kept for backward
/// compatibility with the command-line path; targets the chain's first EQ,
/// inserting one at the end if there is none (matching the command's
/// long-standing auto-create behaviour).
pub fn setEqBand(app: *App, track: u16, band: usize, gain_db: f32) void {
    if (track >= app.session.racks.items.len) return;
    const rack = app.session.racks.items[track];
    const unit = rack.fx.find(.eq) orelse
        rack.fx.insert(app.session.allocator, rack.fx.units.items.len, .eq, app.session.project.sample_rate) catch {
            app.setStatus("eq: chain full", .{});
            return;
        };
    unit.payload.eq.setBand(band, gain_db);
    app.dirty = true;
    var buf: [ws.Rack.chain_cap]dsp.Device = undefined;
    app.session.engine.setTrackChain(track, rack.chain(&buf));
}

/// Same as `setEqBand` but for the master bus — no track index, and pushes
/// the change through `Session.syncMasterChain` instead of `setTrackChain`.
pub fn setMasterEqBand(app: *App, band: usize, gain_db: f32) void {
    const fx = &app.session.master_fx;
    const unit = fx.find(.eq) orelse
        fx.insert(app.session.allocator, fx.units.items.len, .eq, app.session.project.sample_rate) catch {
            app.setStatus("master-eq: chain full", .{});
            return;
        };
    unit.payload.eq.setBand(band, gain_db);
    app.dirty = true;
    app.session.syncMasterChain();
}

// Row layout mirrors views/spectrum.zig's drawFxView exactly: title, the
// 3-row chain strip, a key-hint row, the focused slot's section divider,
// then its editor body. For an EQ unit the body is `visual_rows` spectrum
// rows + an Hz-label row + the band rows; for the other units it's one
// barRow per param (or a single hint row while the chain is empty).

// Chain strip geometry, middle row: an "IN▶" gutter, then up to nine 7-wide
// slot boxes ("┃GATE●┃") joined by 1-wide "▶" arrows; slot i starts at
// column strip_x0 + i*(strip_box_w + strip_gap_w). A trailing "+" box (the
// insert affordance) occupies the next slot position while there's room.
// Nine boxes + "▶OUT" total 78 cols, inside an 80-col terminal.
pub const strip_x0: usize = 3;
pub const strip_box_w: usize = 7;
pub const strip_gap_w: usize = 1;
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

/// Which strip slot a click at column `x` lands in, if any. `len` is the
/// unit count; index `len` means the trailing "+" box (only drawn while
/// the chain has room, so callers gate on that).
fn slotAt(x: usize, len: usize) ?usize {
    if (x < strip_x0) return null;
    const pitch = strip_box_w + strip_gap_w;
    const i = (x - strip_x0) / pitch;
    if ((x - strip_x0) % pitch >= strip_box_w) return null; // the arrow gap
    if (i > len or i >= Fx.max_units) return null;
    return i;
}

/// EQ-body band-row count: bar + value + freq rows (an EQ unit in focus
/// always exists — chains only hold inserted units).
pub const eq_band_rows: usize = 3;

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

/// Click a chain-strip slot box to focus it (the trailing "+" box opens the
/// picker); click an EQ band or a param row to select it; scroll over
/// either nudges it (**ctrl**+scroll = coarse).
pub fn handleMouse(app: *App, ev: modal_mod.MouseEvent, row: usize, cols: u16, view_rows: usize) void {
    _ = cols; // slot/band/param columns here are fixed-width, not terminal-width-dependent
    const is_track = app.view == .track_spectrum;
    const fx = fxPtr(app, is_track) orelse return;
    const compact = compactLayout(view_rows);

    if (row >= strip_rows_start and row <= (if (compact) strip_rows_start else strip_rows_end)) {
        if (ev.kind == .press) {
            const len = fx.units.items.len;
            const i = slotAt(ev.x, len) orelse return;
            if (i == len) openPicker(app, is_track) else setFocus(app, is_track, i);
        }
        return;
    }
    const body0 = bodyRow0(compact);
    if (row < body0) return; // title / hint / section rows — not interactive
    const rel = row - body0;

    const unit = focusedUnit(app, fx) orelse return;
    if (unit.kind() == .eq) {
        // Same sizing as drawFxView: spectrum graph, then the Hz-label row,
        // then the three band rows — only the band rows are interactive.
        const visual_rows: usize = @min(style.spectrum_rows, view_rows -| ((if (compact) @as(usize, 9) else 12) + eq_band_rows));
        const band_row0 = visual_rows + 1;
        if (rel < band_row0 or rel >= band_row0 + eq_band_rows) return;
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

    if (rel >= paramCount(unit.kind())) return;
    switch (ev.kind) {
        .press => app.fx_param = rel,
        .scroll_up, .scroll_down => {
            app.fx_param = rel;
            nudgeMouse(app, is_track, ev);
        },
        else => {},
    }
}

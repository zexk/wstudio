//! Synth-editor input: param row navigation ({/} jump sections, Tab cycles
//! subviews), h/l nudges routed over the engine command queue, and the
//! cursor-row/scroll math shared with the renderer in views/synth.zig.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const App = @import("../app.zig").App;
const spectrum = @import("spectrum.zig");
const piano = @import("piano.zig");
const preset_picker = @import("preset_picker.zig");
const history = @import("../history.zig");
const fuzzy = @import("../fuzzy.zig");
const synth_layout = @import("../synth_layout.zig");

/// The synth editor's three panes, cycled by Tab: oscillator/envelope/
/// filter/voice params ("main"), modulation sources — the matrix, LFOs,
/// ENV 3, macros — ("mod"), and the internal FX section ("fx").
/// `App.synth_cursor` stays one flat param-id space across all three (it
/// IS the PolySynth param id — engine commands and undo key off it
/// directly) — the subview only changes which ids are reachable and how
/// they're laid out on screen. `main`/`mod` are driven by synth_layout.zig's
/// comptime section tables (see `mainOrderNow`/`modOrderNow`); `fx` stays
/// runtime-dynamic (its section set depends on `fx_order` + each unit's
/// on/off flag) and keeps its own machinery below.
pub const Subview = enum { main, mod, fx };

const FxUnitKind = ws.dsp.synth.FxUnitKind;

/// The current synth track's `fx_order`, or the default order as a fallback
/// when the track isn't (yet) resolvable as a synth. Generic over the app
/// type (`anytype`) so both this file's own `*App` call sites and views/
/// synth.zig's generic `drawSynthEditor(app: anytype, ...)` can share it —
/// the latter needs this ahead of its own track-validity check (its row/
/// scroll math runs before that check), so a safe fallback beats an error.
pub fn currentFxOrder(app: anytype) []const FxUnitKind {
    if (app.synth_track >= app.session.racks.items.len) return &ws.dsp.synth.default_fx_order;
    const rack = app.session.racks.items[app.synth_track];
    return switch (rack.instrument) {
        .poly_synth => |*s| &s.fx_order,
        else => &ws.dsp.synth.default_fx_order,
    };
}

/// First/id-count of each FX unit's flat param-id range — the `.fx`
/// subview's row math walks `fx_order` and looks these up per slot instead
/// of the fixed id-range switch every other subview still uses, since FX
/// section screen order now depends on runtime order, not id order.
fn fxFirstId(kind: FxUnitKind) u8 {
    return switch (kind) {
        // zig fmt: off
        .gate    => 132, .comp => 137, .mb_comp => 144, .ott => 161, .eq => 167, .chorus => 176, .freq_shift => 181,
        .dist    => 83, .crush => 86, .flanger => 90, .tape => 188,
        .phaser  => 103, .delay => 108, .reverb => 112,
        // zig fmt: on
    };
}
fn fxIdCount(kind: FxUnitKind) u8 {
    return switch (kind) {
        // zig fmt: off
        .gate    => 4, .comp => 6, .mb_comp => 16, .ott => 5, .eq => 8, .chorus => 4, .freq_shift => 3,
        .dist    => 3, .crush => 4, .flanger => 5, .tape => 6,
        .phaser  => 5, .delay => 4, .reverb => 4,
        // zig fmt: on
    };
}

/// Every cursor-reachable `.fx` id, in on-screen (fx_order) sequence rather
/// than numeric order — the list j/k and g/G walk. Sized generously above
/// the current real total (51 ids across 9 units) for headroom as more
/// units are added.
fn fxVisualIds(order: []const FxUnitKind, buf: []u8) []const u8 {
    var n: usize = 0;
    for (order) |kind| {
        const first = fxFirstId(kind);
        const count = fxIdCount(kind);
        var i: u8 = 0;
        while (i < count) : (i += 1) {
            buf[n] = first + i;
            n += 1;
        }
    }
    return buf[0..n];
}

/// `g`/`G`'s target ids for the current subview: `.main`/`.matrix` just use
/// `firstId`/`lastId` (numeric id order matches visual order there), `.fx`
/// instead jumps to the top/bottom of `fx_order`'s on-screen sequence —
/// see `fxVisualIds`'s doc comment for why numeric extremes are wrong once
/// a unit's been reordered away from its numeric position.
fn fxAwareFirstId(app: *App) u8 {
    if (app.synth_subview != .fx) return firstId(app.synth_subview);
    var buf: [96]u8 = undefined;
    const ids = fxVisualIds(currentFxOrder(app), &buf);
    return if (ids.len > 0) ids[0] else firstId(.fx);
}
fn fxAwareLastId(app: *App) u8 {
    if (app.synth_subview != .fx) return lastId(app.synth_subview);
    var buf: [96]u8 = undefined;
    const ids = fxVisualIds(currentFxOrder(app), &buf);
    return if (ids.len > 0) ids[ids.len - 1] else lastId(.fx);
}

/// `.main`'s `mainOrder` (comptime, width-aware) for the terminal width as
/// of the last draw — see `App.last_cols`'s doc comment for why `handleKey`
/// reads a cached width instead of taking one as a parameter.
fn mainOrderNow(app: *App) []const synth_layout.PositionedEntry {
    return synth_layout.mainOrder(synth_layout.numCols(app.last_cols));
}

/// `.mod`'s counterpart to `mainOrderNow`.
fn modOrderNow(app: *App) []const synth_layout.PositionedEntry {
    return synth_layout.modOrder(synth_layout.numCols(app.last_cols));
}

/// `g`/`G`/Tab's target id for the current subview: `.main`/`.mod` walk
/// their column-grid visual order (see synth_layout.zig), `.fx` keeps
/// `fxAwareFirstId`/`fxAwareLastId`'s existing behavior.
fn cursorFirst(app: *App) u8 {
    return switch (app.synth_subview) {
        .main => synth_layout.firstEntry(mainOrderNow(app)),
        .mod => synth_layout.firstEntry(modOrderNow(app)),
        .fx => fxAwareFirstId(app),
    };
}
fn cursorLast(app: *App) u8 {
    return switch (app.synth_subview) {
        .main => synth_layout.lastEntry(mainOrderNow(app)),
        .mod => synth_layout.lastEntry(modOrderNow(app)),
        .fx => fxAwareLastId(app),
    };
}

/// Which unit's id range `id` falls in, if any — the reverse of
/// `fxFirstId`/`fxIdCount`, used by `<`/`>` to figure out which section the
/// cursor is currently sitting in (order-independent: every kind's id range
/// is fixed regardless of where it sits in `fx_order`).
pub fn fxKindOfId(id: u8) ?FxUnitKind {
    inline for (@typeInfo(FxUnitKind).@"enum".fields) |f| {
        const k: FxUnitKind = @enumFromInt(f.value);
        const first = fxFirstId(k);
        if (id >= first and id < first + fxIdCount(k)) return k;
    }
    return null;
}

/// Maps this synth-internal kind onto the track chain's equivalent so the
/// `.fx` subview's strip/picker can reuse editors/spectrum.zig's label
/// tables (`unitLabel`/`stripLabel`) instead of duplicating them — the two
/// enums share every variant except naming (`dist` here is `sat` there).
pub fn asFxKind(kind: FxUnitKind) ws.FxKind {
    return switch (kind) {
        // zig fmt: off
        .gate => .gate, .comp => .comp, .mb_comp => .mb_comp, .ott => .ott, .eq => .eq,
        .dist => .sat, .crush => .crush, .chorus => .chorus, .flanger => .flanger, .tape => .tape,
        .phaser => .phaser, .freq_shift => .freq_shift, .delay => .delay, .reverb => .reverb,
        // zig fmt: on
    };
}

/// Whether `kind`'s unit is currently in the audible chain — its `fx_*_on`
/// field, the same one `views/synth.zig`'s section renderers already read
/// directly for dimming. The `.fx` subview's strip only lists units this
/// returns true for; picker-insert flips it true, `x` flips it false — no
/// other state changes either way, so nothing is lost toggling repeatedly.
fn fxOn(synth: anytype, kind: FxUnitKind) bool {
    return switch (kind) {
        // zig fmt: off
        .gate => synth.fx_gate_on, .comp => synth.fx_comp_on, .mb_comp => synth.fx_mb_on,
        .ott => synth.fx_ott_on, .eq => synth.fx_eq_on, .dist => synth.fx_dist_on,
        .crush => synth.fx_crush_on, .chorus => synth.fx_chorus_on, .flanger => synth.fx_flanger_on,
        .tape => synth.fx_tape_on,
        .phaser => synth.fx_phaser_on, .freq_shift => synth.fx_freq_shift_on,
        .delay => synth.fx_delay_on, .reverb => synth.fx_reverb_on,
        // zig fmt: on
    };
}

/// One `.fx`-subview strip slot: a labeled unit (`kind` set, `label` its
/// short strip name) or the trailing insert affordance (`kind` null,
/// `label` "+"). `col`/`width` are the strip row's character span, shared
/// verbatim by the renderer (which writes exactly these slots in order,
/// carrying the label itself so views/synth.zig needs no label lookup of
/// its own) and `stripSlotAt` below, so a click can never land somewhere
/// the drawing didn't.
pub const StripSlot = struct { kind: ?FxUnitKind, label: []const u8, col: usize, width: usize };

/// Fixed prefix/suffix around the strip's slot list — see `StripSlot`.
pub const strip_prefix = "IN\u{25B6}";
pub const strip_suffix = "\u{25B6}OUT";

/// Lays out the `.fx` subview's strip: every on unit in `fx_order`
/// sequence, then a trailing `+` while any unit is still off, clipped to
/// `max_cols`. Returns a slice into `buf` (sized for the worst case: 13
/// units + the `+`).
pub fn stripLayout(app: *App, max_cols: usize, buf: *[14]StripSlot) []const StripSlot {
    if (app.synth_track >= app.session.racks.items.len) return &.{};
    const rack = app.session.racks.items[app.synth_track];
    const synth = switch (rack.instrument) {
        .poly_synth => |*s| s,
        else => return &.{},
    };
    var n: usize = 0;
    var col: usize = strip_prefix.len;
    var any_off = false;
    for (synth.fx_order) |kind| {
        if (!fxOn(synth, kind)) {
            any_off = true;
            continue;
        }
        const label = spectrum.stripLabel(asFxKind(kind));
        if (col + label.len + strip_suffix.len > max_cols) break;
        buf[n] = .{ .kind = kind, .label = label, .col = col, .width = label.len };
        n += 1;
        col += label.len + 1; // trailing arrow
    }
    if (any_off and col + 3 + strip_suffix.len <= max_cols) {
        buf[n] = .{ .kind = null, .label = " + ", .col = col, .width = 3 };
        n += 1;
    }
    return buf[0..n];
}

/// Which strip slot (if any) column `x` on the strip row lands in.
fn stripSlotAt(app: *App, max_cols: usize, x: usize) ?StripSlot {
    var buf: [14]StripSlot = undefined;
    for (stripLayout(app, max_cols, &buf)) |slot| {
        if (x >= slot.col and x < slot.col + slot.width) return slot;
    }
    return null;
}

/// `kind`'s dedicated reorder-handle param id — see PolySynth.adjustParam's
/// ids 126-131 and `setFxIndex`'s doc comment for why undo/redo need this
/// to be a real (if synthetic) param id rather than a bespoke message.
fn reorderIdFor(kind: FxUnitKind) u16 {
    return switch (kind) {
        // zig fmt: off
        .dist => 126, .crush => 127, .flanger => 128,
        .phaser => 129, .delay => 130, .reverb => 131,
        .gate => 136, .comp => 143, .mb_comp => 160, .ott => 166, .eq => 175, .chorus => 180, .freq_shift => 184,
        .tape => 194,
        // zig fmt: on
    };
}

/// `<`/`>` in the FX subview: nudges whichever unit's section the cursor
/// currently sits in one slot toward `dir` in `fx_order`. Mirrors the
/// master FX chain editor's own `<`/`>` (`moveFocused` in
/// editors/spectrum.zig) closely enough to feel like the same control, but
/// swaps this fixed unit's slot instead of an ArrayList index. Routed
/// through the same (id, steps) command + undo plumbing every other param
/// nudge uses (see `adjustParam` ids 126-131), not a bespoke message — the
/// `x`/`a` insert/remove pair below (`removeFocusedFx`/
/// `insertFromSynthFxPicker`) rides the same plumbing, just on each unit's
/// on/off id instead of its reorder id.
fn reorderSelectedFx(app: *App, dir: i32) void {
    if (app.synth_subview != .fx) return;
    if (app.synth_track >= app.session.racks.items.len) return;
    const rack = app.session.racks.items[app.synth_track];
    switch (rack.instrument) {
        .poly_synth => {},
        else => return,
    }
    const kind = fxKindOfId(app.synth_cursor) orelse return;
    const id = reorderIdFor(kind);
    app.dirty = true;
    history.noteParamNudge(app, app.synth_track, id, dir);
    _ = app.session.engine.send(.{ .set_track_param = .{
        .track = app.synth_track,
        .id = id,
        .steps = dir,
    } });
    updateScroll(app);
}

/// Sends one nudge on `id` (flips a bool field the same way `l` nudging
/// that row by hand would) through the exact command-queue + undo pair
/// `reorderSelectedFx`/`adjustParam` already use, then flushes it
/// immediately — unlike a held `h`/`l` run, insert and remove are each a
/// single discrete action, not a batch to coalesce. Without the immediate
/// flush, an insert followed straight by a remove on the same id (no
/// cursor move in between to flush the first one) would coalesce into one
/// pending nudge whose captured before-value predates the insert — one
/// `u` would then silently undo both at once instead of stepping back
/// through them individually.
fn sendFxToggle(app: *App, id: u8) void {
    app.dirty = true;
    history.noteParamNudge(app, app.synth_track, id, 1);
    history.flushParamNudge(app);
    _ = app.session.engine.send(.{ .set_track_param = .{
        .track = app.synth_track,
        .id = id,
        .steps = 1,
    } });
}

/// Off units in `fx_order` sequence — the `.fx` subview's insert-picker
/// list. Shared by the picker's render and its key/mouse handlers so they
/// can't disagree about what row N means.
pub fn synthFxPickerKinds(app: *App, buf: *[14]FxUnitKind) []const FxUnitKind {
    if (app.synth_track >= app.session.racks.items.len) return &.{};
    const rack = app.session.racks.items[app.synth_track];
    const synth = switch (rack.instrument) {
        .poly_synth => |*s| s,
        else => return &.{},
    };
    var n: usize = 0;
    for (synth.fx_order) |kind| {
        if (!fxOn(synth, kind)) {
            buf[n] = kind;
            n += 1;
        }
    }
    return buf[0..n];
}

/// The `/` filter narrowing the synth-internal FX picker right now — same
/// live-while-typing rule `spectrum.activeFilter` uses for the track chain's
/// own FX picker.
pub fn activeFxFilter(app: *App) []const u8 {
    if (app.modal.mode == .search and app.view == .synth_fx_picker)
        return app.modal.cmd_buf[0..app.modal.cmd_len];
    return app.synth_fx_picker_filter_buf[0..app.synth_fx_picker_filter_len];
}

/// `synthFxPickerKinds` narrowed by the active filter, matched against each
/// unit's display label.
pub fn filteredSynthFxPickerKinds(app: *App, buf: *[14]FxUnitKind) []const FxUnitKind {
    var off_buf: [14]FxUnitKind = undefined;
    const off = synthFxPickerKinds(app, &off_buf);
    const filter = activeFxFilter(app);
    var n: usize = 0;
    for (off) |k| {
        if (filter.len > 0 and !fuzzy.matches(filter, spectrum.unitLabel(asFxKind(k)))) continue;
        buf[n] = k;
        n += 1;
    }
    return buf[0..n];
}

/// `a` in the `.fx` subview: opens the insert picker, unless every unit is
/// already on.
pub fn openFxPicker(app: *App) void {
    if (app.synth_subview != .fx) return;
    var buf: [14]FxUnitKind = undefined;
    if (synthFxPickerKinds(app, &buf).len == 0) {
        app.setStatus("all FX units already in chain", .{});
        return;
    }
    app.synth_fx_picker_cursor = 0;
    app.synth_fx_picker_filter_len = 0;
    app.view = .synth_fx_picker;
}

/// Picker accepted: flips `kind`'s on id true, focuses its section, and
/// returns to the `.fx` subview.
pub fn insertFromSynthFxPicker(app: *App, kind: FxUnitKind) void {
    app.view = .synth_editor;
    sendFxToggle(app, fxFirstId(kind));
    app.synth_cursor = fxFirstId(kind);
    updateScroll(app);
    app.setStatus("{s} inserted", .{spectrum.unitLabel(asFxKind(kind))});
}

/// Picker dismissed: back to the `.fx` subview, nothing inserted.
pub fn cancelSynthFxPicker(app: *App) void {
    app.view = .synth_editor;
}

/// `x` in the `.fx` subview: turns off whichever unit's section the cursor
/// sits in. A no-op if the unit is already off (unlike a bare `l` nudge on
/// its own id, which would turn it back on).
fn removeFocusedFx(app: *App) void {
    if (app.synth_subview != .fx) return;
    if (app.synth_track >= app.session.racks.items.len) return;
    const rack = app.session.racks.items[app.synth_track];
    const synth = switch (rack.instrument) {
        .poly_synth => |*s| s,
        else => return,
    };
    const kind = fxKindOfId(app.synth_cursor) orelse return;
    if (!fxOn(synth, kind)) return;
    sendFxToggle(app, fxFirstId(kind));
    app.setStatus("{s} removed", .{spectrum.unitLabel(asFxKind(kind))});
}

/// `}`/`{` in the FX subview: moves the cursor to the next/previous
/// section's first id in `fx_order`'s current sequence (not id order — see
/// the `'}', '{'` key handler's own comment). No wrap, matching `.main`/
/// `.matrix`'s sectionStarts-based behavior: past either end, the cursor
/// just stays on the current section's own first id.
fn jumpFxSection(app: *App, forward: bool) void {
    const order = currentFxOrder(app);
    const cur_idx = if (fxKindOfId(app.synth_cursor)) |k|
        std.mem.indexOfScalar(FxUnitKind, order, k)
    else
        null;
    if (forward) {
        const idx = cur_idx orelse return;
        if (idx + 1 < order.len) app.synth_cursor = fxFirstId(order[idx + 1]);
    } else {
        const idx = cur_idx orelse return;
        if (app.synth_cursor == fxFirstId(order[idx]) and idx > 0) {
            app.synth_cursor = fxFirstId(order[idx - 1]);
        } else {
            app.synth_cursor = fxFirstId(order[idx]);
        }
    }
}

/// First/last param id belonging to `subview` — only ever consulted for
/// `.fx` now (`.main`/`.mod` are fully routed through synth_layout.zig's
/// comptime tables; these arms are dead but kept so the switch stays
/// exhaustive until the phase-5 cleanup pass deletes this function).
fn firstId(subview: Subview) u8 {
    return switch (subview) {
        .main => 0,
        .mod => 59,
        .fx => 83,
    };
}
fn lastId(subview: Subview) u8 {
    return switch (subview) {
        .main => 187,
        .mod => 125,
        .fx => 193,
    };
}

/// Whether `id` is rendered/reachable in `subview` — only ever consulted
/// for `.fx` now, see `firstId`'s doc comment.
fn inSubview(id: u8, subview: Subview) bool {
    return switch (subview) {
        .main => (id <= 58 and !deadParam(id)) or (id >= 95 and id <= 102) or (id >= 116 and id <= 125) or (id >= 185 and id <= 187),
        .fx => (id >= 83 and id <= 94) or (id >= 103 and id <= 115) or (id >= 132 and id <= 135) or (id >= 137 and id <= 142) or (id >= 144 and id <= 159) or (id >= 161 and id <= 165) or (id >= 167 and id <= 174) or (id >= 176 and id <= 179) or (id >= 181 and id <= 183) or (id >= 188 and id <= 193),
        .mod => id >= 59 and id <= 82,
    };
}

fn sectionStarts(subview: Subview) []const u8 {
    return switch (subview) {
        // zig fmt: off
        .main => &[_]u8{ 0, 6, 14, 16, 20, 24, 28, 32, 34, 36, 38, 39, 41, 45, 50, 95, 97, 99, 116, 122, 185 },
        .fx   => &[_]u8{ 83, 86, 90, 103, 108, 112, 188 },
        .mod  => &[_]u8{59},
        // zig fmt: on
    };
}

/// Short tag for the editor title when not on the main pane (main shows no
/// tag at all, matching the pre-subview look).
pub fn subviewLabel(subview: Subview) []const u8 {
    return switch (subview) {
        .main => "",
        .mod => "MOD",
        .fx => "FX",
    };
}

// zig fmt: off
pub fn handleKey(app: *App, key: modal_mod.Key) bool {
    switch (key) {
        .escape => { history.flushParamNudge(app); app.view = .tracks; return true; },
        .ctrl_r => { history.doRedo(app); return true; },
        .tab => {
            history.flushParamNudge(app);
            app.synth_subview = switch (app.synth_subview) {
                .main => .mod, .mod => .fx, .fx => .main,
            };
            app.synth_cursor = cursorFirst(app);
            updateScroll(app);
            return true;
        },
        .char => |c| switch (c) {
            // Block insert mode — piano keys conflict with parameter navigation.
            'i' => return true,
            's' => { history.flushParamNudge(app); spectrum.switchToTrack(app, app.synth_track); return true; },
            // p opens the piano roll for this track (matches p in the tracks view);
            // e in the piano roll comes back here, so synth <-> roll is bidirectional.
            'p' => {
                history.flushParamNudge(app);
                piano.switchTo(app, app.synth_track);
                if (app.view == .piano_roll) app.autoSongMode(false);
                return true;
            },
            // f browses factory + saved presets — same apply path as :synth-preset.
            'f' => { history.flushParamNudge(app); preset_picker.open(app, .synth, app.synth_track); return true; },
            'u' => { history.doUndo(app); return true; },
            'U' => { history.doRedo(app); return true; },
            // j/k rows and h/l nudges take a vim count prefix (3j, 5l, …).
            'j' => { moveCursor(app, app.takeCount()); return true; },
            'k' => { moveCursor(app, -app.takeCount()); return true; },
            'h' => { adjustParam(app, -app.takeCount()); return true; },
            'l' => { adjustParam(app, app.takeCount()); return true; },
            'H' => { adjustParam(app, -10 * app.takeCount()); return true; },
            'L' => { adjustParam(app, 10 * app.takeCount()); return true; },
            'g' => { history.flushParamNudge(app); app.synth_cursor = cursorFirst(app); updateScroll(app); return true; },
            'G' => { history.flushParamNudge(app); app.synth_cursor = cursorLast(app); updateScroll(app); return true; },
            // Shift focus within a multi-field entry (a mod-matrix slot's
            // source/dest/depth) — a no-op everywhere else, since every
            // other entry has exactly one field. Safe to bind unconditionally.
            'w' => { shiftField(app, 1); return true; },
            'b' => { shiftField(app, -1); return true; },
            // Reorders the FX chain — see reorderSelectedFx. No-op outside .fx.
            '<' => { reorderSelectedFx(app, -1); return true; },
            '>' => { reorderSelectedFx(app, 1); return true; },
            // Insert/remove for the FX chain strip — see openFxPicker /
            // removeFocusedFx. No-op outside .fx.
            'a' => { openFxPicker(app); return true; },
            'x' => { removeFocusedFx(app); return true; },
            '}', '{' => {
                history.flushParamNudge(app);
                if (app.synth_subview == .fx) {
                    // .fx's section order follows fx_order, which need not
                    // be id-sorted once the user has reordered — walking a
                    // "first id greater than cursor" list (like .matrix's
                    // sectionStarts below) would jump to whatever section
                    // happens to have the next-highest id, not the next
                    // section on screen. Jump by position in fx_order
                    // instead.
                    jumpFxSection(app, c == '}');
                } else if (app.synth_subview == .main) {
                    app.synth_cursor = synth_layout.jumpSection(mainOrderNow(app), app.synth_cursor, c == '}');
                } else if (app.synth_subview == .mod) {
                    app.synth_cursor = synth_layout.jumpSection(modOrderNow(app), app.synth_cursor, c == '}');
                } else {
                    const starts = sectionStarts(app.synth_subview);
                    if (c == '}') {
                        for (starts) |s| {
                            if (s > app.synth_cursor) {
                                app.synth_cursor = s;
                                break;
                            }
                        }
                    } else {
                        var sec_idx: usize = 0;
                        for (starts, 0..) |s, idx| {
                            if (s <= app.synth_cursor) sec_idx = idx;
                        }
                        if (app.synth_cursor == starts[sec_idx] and sec_idx > 0) {
                            app.synth_cursor = starts[sec_idx - 1];
                        } else {
                            app.synth_cursor = starts[sec_idx];
                        }
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

/// Retired param ids (absorbed into the mod matrix) that no longer have an
/// editor row; the cursor steps over them.
fn deadParam(id: u8) bool {
    return id == 23 or id == 30 or id == 31;
}

/// Move the param cursor by `delta` rows within the current subview.
/// `.main`/`.mod` walk their column-grid visual order (see synth_layout.zig
/// — column-major, not numeric id order, once the terminal is wide enough
/// to pack more than one column; a mod-matrix slot's 3 fields count as one
/// row here, preserving whichever field was focused — see
/// synth_layout.moveEntry). `.fx` keeps its prior fx_order-aware behavior.
fn moveCursor(app: *App, delta: i32) void {
    const view = app.synth_subview;
    if (view == .main) {
        app.synth_cursor = synth_layout.moveEntry(mainOrderNow(app), app.synth_cursor, delta);
        updateScroll(app);
        return;
    }
    if (view == .mod) {
        app.synth_cursor = synth_layout.moveEntry(modOrderNow(app), app.synth_cursor, delta);
        updateScroll(app);
        return;
    }
    // .fx's on-screen order follows fx_order, not numeric id order —
    // walking raw ids would get stuck at a unit's numeric id extreme even
    // mid-screen once reordering makes id order diverge from visual
    // order. See fxVisualIds.
    var buf: [96]u8 = undefined;
    const ids = fxVisualIds(currentFxOrder(app), &buf);
    if (ids.len == 0) return;
    const cur: i32 = @intCast(std.mem.indexOfScalar(u8, ids, app.synth_cursor) orelse 0);
    const pos = std.math.clamp(cur + delta, 0, @as(i32, @intCast(ids.len - 1)));
    app.synth_cursor = ids[@intCast(pos)];
    updateScroll(app);
}

/// `w`/`b`: shift focus within the current entry's fields (a mod-matrix
/// slot's source/dest/depth) — see synth_layout.moveField. No-op for `.fx`
/// (no multi-field entries there) and for any `fields == 1` entry.
fn shiftField(app: *App, delta: i32) void {
    const order = switch (app.synth_subview) {
        .main => mainOrderNow(app),
        .mod => modOrderNow(app),
        .fx => return,
    };
    app.synth_cursor = synth_layout.moveField(order, app.synth_cursor, delta);
}
// zig fmt: on

/// Wide terminals split the "main" subview into OSC A / OSC B side by side
/// on top (7 and 9 rows respectively — OSC B is taller, so the top block is
/// 9 rows) followed by every other main-pane section stacked full-width
/// beneath, instead of one long scroll. 108 cols keeps both oscillator
/// columns comfortably above their own widest row (OSC B's 9-row block).
/// The FX and matrix subviews always render as a single full-width list
/// regardless of width — neither has an OSC-A/B-style pairing to split.
pub const two_col_min_cols: usize = 108;

pub fn twoCol(cols: usize) bool {
    return cols >= two_col_min_cols;
}

/// Left column's width in the OSC A/B top block; the right column takes the rest.
pub fn colWidth(cols: usize) usize {
    return cols / 2;
}

/// Row budget of the OSC A/B top block (max of OSC A's 7 rows and OSC B's 9).
pub const top_h: usize = 9;

/// Total body rows (below the shared title) in the "main" subview's wide
/// A/B-over-C layout.
pub const body_rows_wide: usize = 91;
/// Total body rows in the "main" subview's single-column layout.
pub const body_rows_single: usize = 99;
/// Total body rows in the "fx" subview (always single-column).
pub const body_rows_fx: usize = 91;
/// Total body rows in the "matrix" subview (always single-column).
pub const body_rows_matrix: usize = 25;

// zig fmt: off
/// Column + row of `cursor` within the "main" subview's wide layout (row 0
/// is the shared title). OSC A/B (rows 1-9) are side by side, col
/// meaningful; everything else is a single full-width column and col is
/// unused. Must stay in sync with secOscA/secOscB/drawSynthBottom in
/// views/synth.zig, exactly like paramRow mirrors the single-column order.
/// Retired ids (23/30/31) map to row 0, which never matches a body row.
/// Only meaningful for ids `inSubview(id, .main)` — never called otherwise.
pub fn paramColRow(cursor: u8) struct { col: u1, row: usize } {
    return switch (cursor) {
        0...5   => .{ .col = 0, .row = 2  + @as(usize, cursor) },        // OSC A (header at 1)
        6...13  => .{ .col = 1, .row = 2  + @as(usize, cursor - 6) },    // OSC B (header at 1)
        14...15 => .{ .col = 0, .row = 11 + @as(usize, cursor - 14) },   // MOD (header at 10)
        16...19 => .{ .col = 0, .row = 14 + @as(usize, cursor - 16) },   // ENV (header at 13)
        20...22 => .{ .col = 0, .row = 19 + @as(usize, cursor - 20) },   // FILTER (header at 18)
        24...27 => .{ .col = 0, .row = 23 + @as(usize, cursor - 24) },   // FENV (header at 22)
        28...29 => .{ .col = 0, .row = 28 + @as(usize, cursor - 28) },   // LFO (header at 27)
        32...33 => .{ .col = 0, .row = 31 + @as(usize, cursor - 32) },   // VOICE (header at 30)
        34...35 => .{ .col = 0, .row = 34 + @as(usize, cursor - 34) },   // SUB (header at 33)
        36...37 => .{ .col = 0, .row = 37 + @as(usize, cursor - 36) },   // NOISE (header at 36)
        38      => .{ .col = 0, .row = 40 },                             // OUT (header at 39)
        39...40 => .{ .col = 0, .row = 42 + @as(usize, cursor - 39) },   // UNI MODE (header at 41)
        41...44 => .{ .col = 0, .row = 45 + @as(usize, cursor - 41) },   // WARP (header at 44)
        45...49 => .{ .col = 0, .row = 50 + @as(usize, cursor - 45) },   // FILTER 2 (header at 49)
        50...58 => .{ .col = 0, .row = 56 + @as(usize, cursor - 50) },   // OSC C (header at 55)
        95...96 => .{ .col = 0, .row = 66 + @as(usize, cursor - 95) },   // LFO 2 (header at 65)
        97...98 => .{ .col = 0, .row = 69 + @as(usize, cursor - 97) },   // LFO 3 (header at 68)
        99...102 => .{ .col = 0, .row = 72 + @as(usize, cursor - 99) },  // MACRO (header at 71)
        116...121 => .{ .col = 0, .row = 77 + @as(usize, cursor - 116) }, // ARP (header at 76)
        122...125 => .{ .col = 0, .row = 84 + @as(usize, cursor - 122) }, // ENV 3 (header at 83)
        185...187 => .{ .col = 0, .row = 89 + @as(usize, cursor - 185) }, // WAVETABLE (header at 88)
        else    => .{ .col = 0, .row = 0 },
    };
}

/// Row index of `cursor` within `subview`'s single-column rendering (0-based,
/// title excluded). Must stay in sync with the section calls in
/// views/synth.zig's drawSynthEditor/drawSynthBottom. `fx_order` is only
/// consulted for `.fx` (see `currentFxOrder`) — pass whatever's convenient
/// for `.main`/`.matrix` callers.
pub fn paramRow(subview: Subview, cursor: u8, fx_order: []const FxUnitKind) usize {
    return switch (subview) {
        .main => switch (cursor) {
            0...5  => 2 + @as(usize, cursor),          // OSC A (header at row 1)
            6...13 => 9 + @as(usize, cursor - 6),      // OSC B (header at row 8)
            14...15 => 18 + @as(usize, cursor - 14),   // MOD (header at 17)
            16...19 => 21 + @as(usize, cursor - 16),   // ENV (header at 20)
            20...22 => 26 + @as(usize, cursor - 20),   // FILTER (header at 25)
            24...27 => 30 + @as(usize, cursor - 24),   // FENV (header at 29)
            28...29 => 35 + @as(usize, cursor - 28),   // LFO (header at 34)
            32...33 => 39 + @as(usize, cursor - 32),   // VOICE (header at 38)
            34...35 => 42 + @as(usize, cursor - 34),   // SUB (header at 41)
            36...37 => 45 + @as(usize, cursor - 36),   // NOISE (header at 44)
            38      => 48,                              // OUT (header at 47)
            39...40 => 50 + @as(usize, cursor - 39),   // UNI MODE (header at 49)
            41...44 => 53 + @as(usize, cursor - 41),   // WARP (header at 52)
            45...49 => 58 + @as(usize, cursor - 45),   // FILTER 2 (header at 57)
            50...58 => 64 + @as(usize, cursor - 50),   // OSC C (header at 63)
            95...96 => 74 + @as(usize, cursor - 95),   // LFO 2 (header at 73)
            97...98 => 77 + @as(usize, cursor - 97),   // LFO 3 (header at 76)
            99...102 => 80 + @as(usize, cursor - 99),  // MACRO (header at 79)
            116...121 => 85 + @as(usize, cursor - 116), // ARP (header at 84)
            122...125 => 92 + @as(usize, cursor - 122), // ENV 3 (header at 91)
            185...187 => 97 + @as(usize, cursor - 185), // WAVETABLE (header at 96)
            else    => 0,
        },
        .fx => blk: {
            var row: usize = 1;
            for (fx_order) |kind| {
                const first = fxFirstId(kind);
                const count = fxIdCount(kind);
                if (cursor >= first and cursor < first + count) {
                    break :blk row + 1 + (cursor - first); // +1 for this section's own header row
                }
                row += 1 + count;
            }
            break :blk 0;
        },
        .mod => switch (cursor) {
            59...82 => 2 + @as(usize, cursor - 59), // MATRIX (header at 1)
            else    => 0,
        },
    };
}
// zig fmt: on

pub fn updateScroll(app: *App) void {
    // Will be re-clamped against the real max_rows at draw time (views/
    // synth.zig's drawSynthEditor); this is just a same-ballpark estimate
    // so the scroll is already reasonable before that first real draw.
    // Was 20 (tuned against the old rows-|5 body budget, pre-hr()-removal);
    // bumped by the same +2 the real budget gained.
    const max_rows: usize = 22;
    if (app.synth_subview == .main or app.synth_subview == .mod) {
        // 0-based column-local row numbering — see synth_layout.zig's
        // PositionedEntry / views/synth.zig's drawSynthMain/drawSynthMod,
        // which this must stay in lockstep with.
        const order = if (app.synth_subview == .main) mainOrderNow(app) else modOrderNow(app);
        const idx = synth_layout.indexContaining(order, app.synth_cursor) orelse 0;
        const row = if (order.len > 0) order[idx].row else 0;
        if (row < app.synth_scroll) app.synth_scroll = row;
        if (row >= app.synth_scroll + max_rows) app.synth_scroll = row - max_rows + 1;
        return;
    }
    const row = paramRow(app.synth_subview, app.synth_cursor, currentFxOrder(app));
    if (row < app.synth_scroll) app.synth_scroll = row;
    if (row >= app.synth_scroll + max_rows) app.synth_scroll = row - max_rows + 1;
}

// zig fmt: off
/// Nudge the selected synth-editor parameter. The change is routed over the
/// engine command queue and applied on the audio thread (PolySynth.adjustParam)
/// so it never races the block reader — the editor view reflects it on the
/// next frame. See engine.Command.set_track_param. Also notes the nudge for
/// undo (history.noteParamNudge), coalescing a run of h/l presses on the
/// same param into one undo step.
fn adjustParam(app: *App, steps: i32) void {
    if (app.synth_track >= app.session.racks.items.len) return;
    const rack = app.session.racks.items[app.synth_track];
    switch (rack.instrument) {
        .poly_synth => {},
        else => return,
    }
    app.dirty = true;
    history.noteParamNudge(app, app.synth_track, app.synth_cursor, steps);
    _ = app.session.engine.send(.{ .set_track_param = .{
        .track = app.synth_track,
        .id    = app.synth_cursor,
        .steps = steps,
    } });
}
// zig fmt: on

/// The param index whose row (in the *scrolled* on-screen layout) is `row`,
/// or null for the title row / a row that doesn't land on any param (a
/// section-header line). `.main`/`.mod` resolve against `synth_layout`'s
/// comptime column/row positions (0-based content-row numbering — see
/// `drawSynthMain`/`drawSynthMod`); `.fx` keeps scanning `paramRow`'s
/// 1-based numbering as before. A mod-matrix slot's dest/depth fields
/// aren't individually mouse-addressable — a click anywhere on the slot's
/// one line lands on its source field (offset 0); `w`/`b` refine from there.
fn paramAtRow(app: *App, row: usize, x: usize, cols: u16) ?u8 {
    if (row == 0) return null; // title
    const view = app.synth_subview;
    if (view == .main or view == .mod) {
        const full_row = app.synth_scroll + row - 1;
        const n = synth_layout.numCols(cols);
        const cw = synth_layout.colWidth(cols, n);
        const col = @min(@as(usize, x) / cw, n - 1);
        const order = if (view == .main) synth_layout.mainOrder(n) else synth_layout.modOrder(n);
        for (order) |pe| {
            if (pe.col == col and pe.row == full_row) return pe.id;
        }
        return null;
    }
    const full_row = app.synth_scroll + row;
    const fx_order = currentFxOrder(app);
    var i: u8 = firstId(view);
    while (i <= lastId(view)) : (i += 1) {
        if (!inSubview(i, view)) continue;
        const row_i = paramRow(view, i, fx_order);
        if (row_i == full_row) return i;
    }
    return null;
}

/// Click a param row to select it. Scroll over a param row nudges it via
/// the existing `adjustParam` (same step `h`/`l` use); **ctrl**+scroll is
/// the coarse step (matches `H`/`L`). In the `.fx` subview, row 1 is the
/// fixed chain strip (not part of the scrolled body — see views/synth.zig's
/// drawSynthEditor) — a click there focuses the clicked unit or opens the
/// insert picker; body rows below it are offset by one to compensate.
pub fn handleMouse(app: *App, ev: modal_mod.MouseEvent, row: usize, cols: u16) void {
    if (app.synth_subview == .fx and row == 1) {
        if (ev.kind == .press) {
            const slot = stripSlotAt(app, cols, ev.x) orelse return;
            history.flushParamNudge(app);
            if (slot.kind) |k| {
                app.synth_cursor = fxFirstId(k);
                updateScroll(app);
            } else openFxPicker(app);
        }
        return;
    }
    const body_row = if (app.synth_subview == .fx and row >= 2) row - 1 else row;
    switch (ev.kind) {
        .press => {
            const p = paramAtRow(app, body_row, ev.x, cols) orelse return;
            history.flushParamNudge(app);
            app.synth_cursor = p;
            updateScroll(app);
        },
        .scroll_up, .scroll_down => {
            const p = paramAtRow(app, body_row, ev.x, cols) orelse return;
            app.synth_cursor = p;
            updateScroll(app);
            const dir: i32 = if (ev.kind == .scroll_up) 1 else -1;
            adjustParam(app, dir * (if (ev.ctrl) @as(i32, 10) else 1));
        },
        else => {},
    }
}

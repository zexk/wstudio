//! Pattern-editing `:` commands split out of commands.zig - transpose,
//! reverse, humanize, chop, glue, arpeggiate, and the rest of the piano-roll
//! note-range editing surface.

const std = @import("std");
const ws = @import("wstudio");
const types = ws.types;
const engine_mod = ws.engine;
const dsp = ws.dsp.device;
const DrumMachine = ws.dsp.DrumMachine;
const Sampler = ws.dsp.Sampler;
const Slicer = ws.dsp.Slicer;
const cmd_mod = @import("cmd.zig");
const config_mod = @import("../config.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const history = @import("history.zig");
const piano_ed = @import("editors/piano.zig");
const preset_ed = @import("editors/preset_picker.zig");
const spectrum_ed = @import("editors/fx_editor.zig");
const theory = ws.theory;
const pattern_mod = ws.dsp.pattern;
const user_presets = @import("user_presets.zig");
const user_drum_kits = @import("user_drum_kits.zig");
const help_view = @import("help.zig");
const cu = @import("commands_util.zig");
const commands = @import("commands.zig");
const path_buf_len = commands.path_buf_len;
const parseFiniteFloat = commands.parseFiniteFloat;
const expandHome = commands.expandHome;
const cmdScale = commands.cmdScale;

const resolveMelodic = cu.resolveMelodic;
const cursorDrumTrack = cu.cursorDrumTrack;
const cursorDrumMachine = cu.cursorDrumMachine;
const readFileForLoad = cu.readFileForLoad;

/// `:reverse` - retrograde. A melodic pattern (piano roll open, or the
/// cursor on a melodic track) mirrors in time so the figure plays
/// backwards; a drum machine mirrors its whole grid, all pads. Reversing a
/// slice of the piano roll is visual-mode `r` (the `:` prompt isn't
/// reachable from visual mode).
pub fn cmdReverse(app: *App, _: []const u8) void {
    // Same track-resolution rule as :clear, falling through to the drum
    // machine so the command also works from the tracks and drum views.
    if (resolveMelodic(app)) |m| {
        history.recordMelodic(app, @intCast(m.track));
        const moved = m.pp.reverseNotesInRange(.{ .lo_beat = 0.0, .hi_beat = m.pp.length_beats });
        app.setStatus("reversed {d} notes", .{moved});
        piano_ed.syncLinkedClip(app);
        return;
    }
    if (cursorDrumTrack(app)) |drum_track| {
        const dm = cursorDrumMachine(app).?;
        history.recordDrum(app, drum_track);
        dm.reversePattern();
        app.setStatus("reversed the drum pattern", .{});
        return;
    }
    app.setStatus("reverse: no pattern here", .{});
}

/// `:invert [pitch]` - the vertical twin of `:reverse`: mirror every note
/// around a pitch axis (default: the pattern's opening note, so the phrase
/// still starts where it did and only folds from there), turning an ascending
/// figure into its descending answer. A note whose mirror would leave 0-127
/// stays put instead of piling up on the boundary. Melodic only - a drum
/// machine's pads aren't a pitch axis. Same track-resolution rule as `:clear`.
pub fn cmdInvert(app: *App, args: []const u8) void {
    const m = resolveMelodic(app) orelse {
        app.setStatus("invert: no piano-roll pattern", .{});
        return;
    };
    const trimmed = std.mem.trim(u8, args, " ");
    const axis: u7 = if (trimmed.len == 0)
        m.pp.firstNotePitch() orelse {
            app.setStatus("invert: the pattern is empty", .{});
            return;
        }
    else
        std.fmt.parseInt(u7, trimmed, 10) catch {
            app.setStatus("invert: expected a MIDI pitch 0-127, e.g. :invert 60", .{});
            return;
        };
    var table: [128]u7 = undefined;
    for (&table, 0..) |*to, p| {
        const mirrored = 2 * @as(i32, axis) - @as(i32, @intCast(p));
        to.* = if (mirrored >= 0 and mirrored <= 127) @intCast(mirrored) else @intCast(p);
    }
    history.recordMelodic(app, @intCast(m.track));
    const moved = m.pp.remapPitch(.{ .lo_beat = 0.0, .hi_beat = m.pp.length_beats }, &table);
    app.setStatus("inverted {d} notes around pitch {d}", .{ moved, axis });
    piano_ed.syncLinkedClip(app);
}

/// `:double` - copy the pattern after itself and double the loop length, so a
/// one-bar idea becomes a two-bar phrase whose back half you can then vary.
/// Melodic only: a drum machine's length is its own step count, which the
/// drum view's `+`/`-` already resize. Same track-resolution rule as `:clear`.
pub fn cmdDouble(app: *App, _: []const u8) void {
    const m = resolveMelodic(app) orelse {
        app.setStatus("double: no piano-roll pattern", .{});
        return;
    };
    var entry = history.captureMelodic(app, @intCast(m.track));
    if (!m.pp.doubleLength()) {
        if (entry) |*e| e.deinit(app.allocator);
        app.setStatus("double: the pattern is empty, or its copy wouldn't fit", .{});
        return;
    }
    history.push(app, entry);
    app.setStatus("doubled to {d:.0} beats, {d} notes", .{ m.pp.length_beats, m.pp.note_count });
    piano_ed.syncLinkedClip(app);
}

/// `:fit` - shrink (or grow) the loop to the bar the last note ends in, so a
/// pattern sketched inside an 8-bar default loops as the 2 bars it actually
/// is. Rounds up to a whole bar rather than to the raw note-off: a loop that
/// cuts mid-bar fights every other pattern in the session. Melodic only,
/// same track-resolution rule as `:clear`.
pub fn cmdFit(app: *App, _: []const u8) void {
    const m = resolveMelodic(app) orelse {
        app.setStatus("fit: no piano-roll pattern", .{});
        return;
    };
    const end = m.pp.contentEndBeat();
    if (end <= 0.0) {
        app.setStatus("fit: the pattern is empty", .{});
        return;
    }
    const bar: f64 = @floatFromInt(app.session.project.beats_per_bar);
    const fitted = @max(bar, @ceil(end / bar - 1e-9) * bar);
    if (@abs(fitted - m.pp.length_beats) < 1e-9) {
        app.setStatus("fit: the loop already ends on {d:.0} beats", .{fitted});
        return;
    }
    history.recordMelodic(app, @intCast(m.track));
    m.pp.length_beats = fitted;
    const bars = fitted / bar;
    app.setStatus("loop fitted to {d:.0} beats ({d:.0} bar{s})", .{ fitted, bars, if (bars < 1.5) "" else "s" });
    piano_ed.syncLinkedClip(app);
}

/// `:dedupe` - drop notes stacked on an identical pitch and start, keeping
/// the longest of each pile. Repeated stamps and layered pastes leave these
/// behind, and they don't just waste the pattern's note budget: the first
/// copy's note_off chokes the second, so a doubled note plays short.
/// Melodic only - a drum grid can't hold two hits in one cell. Same
/// track-resolution rule as `:clear`.
pub fn cmdDedupe(app: *App, _: []const u8) void {
    const m = resolveMelodic(app) orelse {
        app.setStatus("dedupe: no piano-roll pattern", .{});
        return;
    };
    var entry = history.captureMelodic(app, @intCast(m.track));
    const removed = m.pp.dedupe(.{ .lo_beat = 0.0, .hi_beat = m.pp.length_beats });
    if (removed == 0) {
        if (entry) |*e| e.deinit(app.allocator);
        app.setStatus("dedupe: no stacked notes", .{});
        return;
    }
    history.push(app, entry);
    app.setStatus("removed {d} stacked note{s}", .{ removed, if (removed == 1) "" else "s" });
    piano_ed.syncLinkedClip(app);
}

/// `:normalize` - scale every velocity up until the loudest note hits full,
/// keeping the dynamics between notes intact. The rescue for a take played
/// too timid, where `:vel-ramp` would flatten the performance instead. Falls
/// through to the drum machine (same track-resolution rule as `:reverse`),
/// which normalizes its whole kit against its own loudest hit.
pub fn cmdNormalize(app: *App, _: []const u8) void {
    if (resolveMelodic(app)) |m| {
        var entry = history.captureMelodic(app, @intCast(m.track));
        const touched = m.pp.normalizeVelocity(.{ .lo_beat = 0.0, .hi_beat = m.pp.length_beats });
        if (touched == 0) {
            if (entry) |*e| e.deinit(app.allocator);
            app.setStatus("normalize: nothing to lift - already peaking, or empty", .{});
            return;
        }
        history.push(app, entry);
        app.setStatus("normalized {d} note velocities", .{touched});
        piano_ed.syncLinkedClip(app);
        return;
    }
    if (cursorDrumTrack(app)) |drum_track| {
        const dm = cursorDrumMachine(app).?;
        var entry = history.captureDrum(app, drum_track);
        const touched = dm.normalizeVelocity();
        if (touched == 0) {
            if (entry) |*e| e.deinit(app.allocator);
            app.setStatus("normalize: nothing to lift - already peaking, or empty", .{});
            return;
        }
        history.push(app, entry);
        app.setStatus("normalized {d} hit velocities", .{touched});
        return;
    }
    app.setStatus("normalize: no pattern here", .{});
}

/// `:vel-ramp <from> <to>` - linear velocity ramp, both ends 0-100%. A
/// melodic pattern interpolates every note from `from` at its first note to
/// `to` at its last; a drum machine ramps the cursor pad's hits instead -
/// the classic hi-hat build (or fade) in one command. Same track-resolution
/// rule as `:reverse`.
pub fn cmdVelRamp(app: *App, args: []const u8) void {
    const usage = "usage: vel-ramp <from> <to> (0-100%), e.g. :vel-ramp 30 100";
    var it = std.mem.tokenizeScalar(u8, args, ' ');
    const from_str = it.next() orelse {
        app.setStatus("{s}", .{usage});
        return;
    };
    const to_str = it.next() orelse {
        app.setStatus("{s}", .{usage});
        return;
    };
    const from = parseFiniteFloat(f32, from_str) catch {
        app.setStatus("{s}", .{usage});
        return;
    };
    const to = parseFiniteFloat(f32, to_str) catch {
        app.setStatus("{s}", .{usage});
        return;
    };
    if (from < 0.0 or from > 100.0 or to < 0.0 or to > 100.0) {
        app.setStatus("vel-ramp: values must be 0-100", .{});
        return;
    }
    if (resolveMelodic(app)) |m| {
        history.recordMelodic(app, @intCast(m.track));
        const touched = m.pp.velocityRamp(0.0, m.pp.length_beats, from / 100.0, to / 100.0);
        app.setStatus("velocity ramp {d:.0}% -> {d:.0}% across {d} notes", .{ from, to, touched });
        piano_ed.syncLinkedClip(app);
        return;
    }
    if (cursorDrumTrack(app)) |drum_track| {
        const dm = cursorDrumMachine(app).?;
        const pad: u8 = @intCast(app.drum_cursor[0]);
        history.recordDrum(app, drum_track);
        const v0: u8 = @intFromFloat(@round(from / 100.0 * 127.0));
        const v1: u8 = @intFromFloat(@round(to / 100.0 * 127.0));
        const touched = dm.velocityRampPad(pad, v0, v1);
        app.setStatus("velocity ramp {d:.0}% -> {d:.0}% across {d} hits on pad {d} ({s})", .{ from, to, touched, pad + 1, dm.padName(pad) });
        return;
    }
    app.setStatus("vel-ramp: no pattern here", .{});
}

/// `:legato` - extend every note in the pattern to the next note's onset (any
/// pitch), closing staccato gaps so a line plays gapless. Chords sharing a
/// start all reach the same next onset; the pattern's last onset extends to
/// the loop end. Melodic only - a drum hit has no "next note" to reach for,
/// so this doesn't fall through to the drum machine like `:reverse`/
/// `:vel-ramp` do. Same track-resolution rule as `:clear`.
pub fn cmdLegato(app: *App, _: []const u8) void {
    const m = resolveMelodic(app) orelse {
        app.setStatus("legato: no piano-roll pattern", .{});
        return;
    };
    history.recordMelodic(app, @intCast(m.track));
    const changed = m.pp.legato(0.0, m.pp.length_beats);
    app.setStatus("legato: extended {d} notes", .{changed});
    piano_ed.syncLinkedClip(app);
}

/// `:glue` - weld every run of touching or overlapping same-pitch notes
/// into one long note (FL's glue tool). Melodic only, same track-resolution
/// rule as `:legato`; a drum hit has no length to weld.
pub fn cmdGlue(app: *App, _: []const u8) void {
    const m = resolveMelodic(app) orelse {
        app.setStatus("glue: no piano-roll pattern", .{});
        return;
    };
    var entry = history.captureMelodic(app, @intCast(m.track));
    const merged = m.pp.glue(.{ .lo_beat = 0.0, .hi_beat = m.pp.length_beats });
    if (merged == 0) {
        if (entry) |*e| e.deinit(app.allocator);
        app.setStatus("glue: nothing adjacent to weld", .{});
        return;
    }
    history.push(app, entry);
    app.setStatus("glued {d} notes", .{merged});
    piano_ed.syncLinkedClip(app);
}

/// `:chop-notes` - split every note into pieces one view-grid step long
/// (the inverse of `:glue`), the fast way to turn held notes into a
/// stutter. Uses `piano_division` like `:quantize` does, so `z`/`Z`/`T`
/// pick the resolution. Refuses outright when the split wouldn't fit in the
/// pattern's fixed note capacity rather than chopping half of it. Named for
/// FL's "chop notes" rather than plain `:chop`, which the slicer's
/// transient chop already owns.
pub fn cmdChopNotes(app: *App, _: []const u8) void {
    const m = resolveMelodic(app) orelse {
        app.setStatus("chop-notes: no piano-roll pattern", .{});
        return;
    };
    const step_beats = 1.0 / @as(f64, @floatFromInt(app.pianoStepsPerBeat()));
    var entry = history.captureMelodic(app, @intCast(m.track));
    const added = m.pp.chop(.{ .lo_beat = 0.0, .hi_beat = m.pp.length_beats }, step_beats) orelse {
        if (entry) |*e| e.deinit(app.allocator);
        app.setStatus("chop-notes: would exceed {d} notes", .{pattern_mod.max_notes});
        return;
    };
    if (added == 0) {
        if (entry) |*e| e.deinit(app.allocator);
        app.setStatus("chop-notes: every note is already one {s} or shorter", .{app.piano_division.label()});
        return;
    }
    history.push(app, entry);
    app.setStatus("chopped into {s}: {d} new notes", .{ app.piano_division.label(), added });
    piano_ed.syncLinkedClip(app);
}

/// `:transpose <semitones>` - shift every note in the whole pattern, the
/// `:` counterpart to visual-mode j/k/J/K (which only cover the selection).
/// All-or-nothing at the MIDI range edges, same as the visual version - see
/// `shiftNotesInRange`. Melodic only, same reasoning as `:legato`: a drum
/// hit is a fixed sample, not a pitched note to shift.
pub fn cmdTranspose(app: *App, args: []const u8) void {
    const m = resolveMelodic(app) orelse {
        app.setStatus("transpose: no piano-roll pattern", .{});
        return;
    };
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        app.setStatus("usage: transpose <semitones>, e.g. :transpose -12", .{});
        return;
    }
    const dpitch = std.fmt.parseInt(i32, trimmed, 10) catch {
        app.setStatus("transpose: bad semitone count '{s}'", .{trimmed});
        return;
    };
    var entry = history.captureMelodic(app, @intCast(m.track));
    const moved = m.pp.shiftNotesInRange(.{ .lo_beat = 0.0, .hi_beat = m.pp.length_beats }, dpitch, 0.0) orelse {
        if (entry) |*e| e.deinit(app.allocator);
        app.setStatus("can't transpose - would leave the pitch range", .{});
        return;
    };
    if (moved == 0) {
        if (entry) |*e| e.deinit(app.allocator);
        app.setStatus("transpose: no notes in the pattern", .{});
        return;
    }
    history.push(app, entry);
    app.setStatus("transposed {d} notes {s}{d} st", .{ moved, if (dpitch >= 0) "+" else "", dpitch });
    piano_ed.syncLinkedClip(app);
}

/// `:strum <ms>` - stagger every chord (notes sharing a start) by `ms` per
/// rank: positive strums low-to-high (bass note on the beat, a down-strum),
/// negative high-to-low (an up-strum). Tempo-aware - `ms` converts to beats
/// via the project's current BPM, same source `:seek` reads. Melodic only:
/// a drum hit has no fractional timing to offset into, same reasoning as
/// `:legato`/`:transpose`.
pub fn cmdStrum(app: *App, args: []const u8) void {
    const m = resolveMelodic(app) orelse {
        app.setStatus("strum: no piano-roll pattern", .{});
        return;
    };
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        app.setStatus("usage: strum <ms> (negative = high-to-low), e.g. :strum 20", .{});
        return;
    }
    const ms = parseFiniteFloat(f64, trimmed) catch {
        app.setStatus("strum: expected milliseconds, e.g. :strum 20", .{});
        return;
    };
    const bpm = @max(app.session.project.tempo_bpm, 1.0);
    const offset_beats = ms / 60_000.0 * bpm;
    history.recordMelodic(app, @intCast(m.track));
    const touched = m.pp.strum(0.0, m.pp.length_beats, offset_beats);
    if (touched == 0) {
        app.setStatus("strum: no chords in the pattern", .{});
        return;
    }
    app.setStatus("strummed {d} notes ({s}{d:.0}ms)", .{ touched, if (ms >= 0) "+" else "", ms });
    piano_ed.syncLinkedClip(app);
}

/// `:flam <ms> [repeats]` - echo every note `ms` apart at fading velocity,
/// the drum-roll ornament (FL's flam). Negative `ms` puts the copies before
/// the note instead, the usual grace-note reading. `repeats` defaults to 1.
/// Melodic only, same track-resolution rule as `:strum`.
pub fn cmdFlam(app: *App, args: []const u8) void {
    const m = resolveMelodic(app) orelse {
        app.setStatus("flam: no piano-roll pattern", .{});
        return;
    };
    var it = std.mem.tokenizeScalar(u8, args, ' ');
    const ms_text = it.next() orelse {
        app.setStatus("usage: flam <ms> [repeats], e.g. :flam -15", .{});
        return;
    };
    const ms = parseFiniteFloat(f64, ms_text) catch {
        app.setStatus("flam: expected milliseconds, e.g. :flam -15", .{});
        return;
    };
    const repeats: u8 = if (it.next()) |text| std.fmt.parseInt(u8, text, 10) catch {
        app.setStatus("flam: bad repeat count '{s}'", .{text});
        return;
    } else 1;
    if (repeats == 0 or repeats > 8) {
        app.setStatus("flam: repeats must be 1-8", .{});
        return;
    }
    const offset_beats = ms / 60_000.0 * @max(app.session.project.tempo_bpm, 1.0);
    var entry = history.captureMelodic(app, @intCast(m.track));
    const added = m.pp.flam(.{ .lo_beat = 0.0, .hi_beat = m.pp.length_beats }, offset_beats, repeats) orelse {
        if (entry) |*e| e.deinit(app.allocator);
        app.setStatus("flam: would exceed {d} notes", .{pattern_mod.max_notes});
        return;
    };
    if (added == 0) {
        if (entry) |*e| e.deinit(app.allocator);
        app.setStatus("flam: nothing to echo", .{});
        return;
    }
    history.push(app, entry);
    app.setStatus("flam: added {d} notes ({s}{d:.0}ms x{d})", .{ added, if (ms >= 0) "+" else "", ms, repeats });
    piano_ed.syncLinkedClip(app);
}

/// `:arpeggiate [down]` - deal every chord out into an arpeggio one view-
/// grid step per note (`z`/`Z`/`T` pick the step, as with `:quantize`),
/// low-to-high unless `down` is given. Chords only: a lone note has no
/// voices to spread, so it stays where it is.
pub fn cmdArpeggiate(app: *App, args: []const u8) void {
    const m = resolveMelodic(app) orelse {
        app.setStatus("arpeggiate: no piano-roll pattern", .{});
        return;
    };
    const trimmed = std.mem.trim(u8, args, " ");
    const down = std.mem.eql(u8, trimmed, "down");
    if (trimmed.len != 0 and !down and !std.mem.eql(u8, trimmed, "up")) {
        app.setStatus("usage: arpeggiate [up|down]", .{});
        return;
    }
    const step_beats = 1.0 / @as(f64, @floatFromInt(app.pianoStepsPerBeat()));
    var entry = history.captureMelodic(app, @intCast(m.track));
    const moved = m.pp.arpeggiate(.{ .lo_beat = 0.0, .hi_beat = m.pp.length_beats }, step_beats, down);
    if (moved == 0) {
        if (entry) |*e| e.deinit(app.allocator);
        app.setStatus("arpeggiate: no chords in the pattern", .{});
        return;
    }
    history.push(app, entry);
    app.setStatus("arpeggiated {d} notes ({s}, {s})", .{ moved, if (down) "down" else "up", app.piano_division.label() });
    piano_ed.syncLinkedClip(app);
}

/// `:limit <lo> <hi>` - fold every note into the MIDI pitch range [lo, hi]
/// by whole octaves, so a line that wandered out of an instrument's
/// register comes back without losing its shape. Pitches are MIDI numbers
/// (60 = C4), the same units `:transpose` counts in.
pub fn cmdLimit(app: *App, args: []const u8) void {
    const m = resolveMelodic(app) orelse {
        app.setStatus("limit: no piano-roll pattern", .{});
        return;
    };
    var it = std.mem.tokenizeScalar(u8, args, ' ');
    const lo_text = it.next() orelse "";
    const hi_text = it.next() orelse "";
    const lo = std.fmt.parseInt(u8, lo_text, 10) catch 128;
    const hi = std.fmt.parseInt(u8, hi_text, 10) catch 128;
    if (lo > 127 or hi > 127 or lo > hi) {
        app.setStatus("usage: limit <lo> <hi>, MIDI pitches 0-127 (e.g. :limit 48 72)", .{});
        return;
    }
    var entry = history.captureMelodic(app, @intCast(m.track));
    const moved = m.pp.limitPitch(.{ .lo_beat = 0.0, .hi_beat = m.pp.length_beats }, @intCast(lo), @intCast(hi));
    if (moved == 0) {
        if (entry) |*e| e.deinit(app.allocator);
        app.setStatus("limit: every note is already in range", .{});
        return;
    }
    history.push(app, entry);
    var lo_buf: [5]u8 = undefined;
    var hi_buf: [5]u8 = undefined;
    app.setStatus("limited {d} notes to {s}-{s}", .{
        moved,
        ws.midi.noteName(@intCast(lo), &lo_buf),
        ws.midi.noteName(@intCast(hi), &hi_buf),
    });
    piano_ed.syncLinkedClip(app);
}

/// `:discard-lengths` - reset every note to the roll's default note length
/// (`[`/`]` with no note under the cursor sets it), throwing away lengths
/// drawn by hand or carried in from a MIDI import.
pub fn cmdDiscardLengths(app: *App, _: []const u8) void {
    const m = resolveMelodic(app) orelse {
        app.setStatus("discard-lengths: no piano-roll pattern", .{});
        return;
    };
    var entry = history.captureMelodic(app, @intCast(m.track));
    const changed = m.pp.setLengths(.{ .lo_beat = 0.0, .hi_beat = m.pp.length_beats }, app.piano_note_len);
    if (changed == 0) {
        if (entry) |*e| e.deinit(app.allocator);
        app.setStatus("discard-lengths: every note is already {d:.2} beats", .{app.piano_note_len});
        return;
    }
    history.push(app, entry);
    app.setStatus("reset {d} notes to {d:.2} beats", .{ changed, app.piano_note_len });
    piano_ed.syncLinkedClip(app);
}

/// `:snap-scale [<root> [<type>]]` - pull every off-scale note onto the
/// nearest tone of the active `:scale` (FL's "snap to key"). The other half
/// of the scale workflow: `:scale` already highlights the key and steers the
/// `c`/`C` chord stamp, but nothing could fix a line that drifted out of it -
/// a recorded take, a `:transpose`, a paste from another key. Args set the
/// scale first, exactly as `:scale` parses them, so `:snap-scale d minor` is
/// the one-shot form; with no args and no scale set there's nothing to snap
/// to and it says so.
pub fn cmdSnapScale(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len > 0) {
        cmdScale(app, trimmed);
        // A bad root/type already reported itself; don't then snap to a
        // stale scale the user didn't ask for.
        if (app.session.project.scale == null) return;
    }
    const scale = app.session.project.scale orelse {
        app.setStatus("snap-scale: no scale set - :scale <root> <type> first", .{});
        return;
    };
    const m = resolveMelodic(app) orelse {
        app.setStatus("snap-scale: no piano-roll pattern", .{});
        return;
    };
    var table: [128]u7 = undefined;
    for (&table, 0..) |*to, pitch| to.* = scale.nearest(@intCast(pitch));
    var entry = history.captureMelodic(app, @intCast(m.track));
    const moved = m.pp.remapPitch(.{ .lo_beat = 0.0, .hi_beat = m.pp.length_beats }, &table);
    if (moved == 0) {
        if (entry) |*e| e.deinit(app.allocator);
        app.setStatus("snap-scale: every note is already in {s} {s}", .{ theory.pitchClassName(scale.root), scale.kind.label() });
        return;
    }
    history.push(app, entry);
    app.setStatus("snapped {d} notes to {s} {s}", .{ moved, theory.pitchClassName(scale.root), scale.kind.label() });
    piano_ed.syncLinkedClip(app);
}

/// `:swing [percent]` - sets the piano-roll pattern's swing, 50 (straight,
/// the default) to 75 (hardest shuffle) - the melodic counterpart to the
/// drum machine's `<`/`>` swing, so a melodic track can match a swung drum
/// groove. Same track-resolution rule as `:clear`/`:humanize`. With no args,
/// reports the current setting (matches `:scale`).
pub fn cmdSwing(app: *App, args: []const u8) void {
    const m = resolveMelodic(app) orelse {
        app.setStatus("swing: no piano-roll pattern", .{});
        return;
    };
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        app.setStatus("swing: {d:.0}%", .{m.pp.swing.load(.monotonic)});
        return;
    }
    const pct = parseFiniteFloat(f32, trimmed) catch {
        app.setStatus("swing: expected a percent, e.g. :swing 62", .{});
        return;
    };
    const before = m.pp.swing.load(.monotonic);
    m.pp.setSwing(pct);
    history.recordSwing(app, @intCast(m.track), before);
    app.setStatus("swing: {d:.0}%", .{m.pp.swing.load(.monotonic)});
}

/// `:import-midi <file>` - replace the piano-roll pattern with a Standard
/// MIDI File's notes and channel events. Source track/channel identity and
/// tempo changes stay attached for round-trip export.
pub fn cmdImportMidi(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        app.setStatus("import-midi: usage :import-midi <file>", .{});
        return;
    }
    const m = resolveMelodic(app) orelse {
        app.setStatus("import-midi: no piano-roll pattern", .{});
        return;
    };
    var path_buf: [path_buf_len]u8 = undefined;
    const path = expandHome(&path_buf, trimmed);
    const data = readFileForLoad(app, path) orelse return;
    defer app.allocator.free(data);
    var result = ws.midi_file.parse(app.allocator, data) catch |e| {
        app.setStatus("import-midi: parse error: {s}", .{@errorName(e)});
        return;
    };
    defer result.deinit(app.allocator);

    history.recordMelodic(app, @intCast(m.track));
    m.pp.setNotes(result.notes, result.length_beats);
    m.pp.setMidiEvents(result.events);
    app.session.project.tempo_bpm = result.tempo_bpm;
    app.session.project.tempo_points.clearRetainingCapacity();
    _ = app.session.engine.send(.clear_time_map);
    _ = app.session.engine.send(.{ .set_tempo = result.tempo_bpm });
    for (result.tempo_points) |point| {
        app.session.project.setTempoPoint(point) catch continue;
        _ = app.session.engine.send(.{ .set_tempo_point = point });
    }
    app.session.syncLoop();
    piano_ed.syncLinkedClip(app);
    if (result.truncated)
        app.setStatus("imported {d} notes (capped at {d}) at {d:.0} BPM", .{ result.notes.len, pattern_mod.max_notes, result.tempo_bpm })
    else
        app.setStatus("imported {d} notes at {d:.0} BPM", .{ result.notes.len, result.tempo_bpm });
}

/// `:export-midi <file>` - write the piano-roll pattern as a format-0
/// Standard MIDI File with project tempo changes and imported channel events.
pub fn cmdExportMidi(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        app.setStatus("export-midi: usage :export-midi <file>", .{});
        return;
    }
    const m = resolveMelodic(app) orelse {
        app.setStatus("export-midi: no piano-roll pattern", .{});
        return;
    };
    var note_buf: [pattern_mod.max_notes]pattern_mod.Note = undefined;
    const count = m.pp.copyNotes(&note_buf);
    var event_buf: [pattern_mod.max_midi_events]pattern_mod.MidiEvent = undefined;
    const event_count = m.pp.copyMidiEvents(&event_buf);

    const bytes = ws.midi_file.writeProject(app.allocator, note_buf[0..count], event_buf[0..event_count], app.session.project.tempo_points.items, app.session.project.tempo_bpm) catch {
        app.setStatus("export-midi: out of memory", .{});
        return;
    };
    defer app.allocator.free(bytes);

    var path_buf: [path_buf_len]u8 = undefined;
    const path = expandHome(&path_buf, trimmed);
    const file = std.Io.Dir.cwd().createFile(app.io, path, .{}) catch |e| {
        app.setStatus("export-midi: cannot write '{s}': {s}", .{ path, @errorName(e) });
        return;
    };
    defer file.close(app.io);
    var write_buf: [8192]u8 = undefined;
    var fw = file.writer(app.io, &write_buf);
    if (fw.interface.writeAll(bytes)) |_| {} else |e| {
        app.setStatus("export-midi: write failed: {s}", .{@errorName(e)});
        return;
    }
    fw.interface.flush() catch |e| {
        app.setStatus("export-midi: write failed: {s}", .{@errorName(e)});
        return;
    };
    app.setStatus("exported {d} notes: {s}", .{ count, path });
}

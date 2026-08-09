//! Content-loading `:` commands split out of commands.zig - synth/drum-kit
//! presets, sample/wavetable/soundfont/clip/slice loading, BPM-sync tuning,
//! and the euclidean-adjacent pad-length/chop-random tools that share their
//! loading path.

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

const resolveTrack = cu.resolveTrack;
const cursorDrumTrack = cu.cursorDrumTrack;
const cursorDrumMachine = cu.cursorDrumMachine;
const readFileForLoad = cu.readFileForLoad;
const loadPadFromPath = cu.loadPadFromPath;
const stemOf = cu.stemOf;
const cursorSlicerTrack = cu.cursorSlicerTrack;
const cursorSlicer = cu.cursorSlicer;

/// The standalone Sampler on the cursor's track, or null.
pub fn cursorSampler(app: *App) ?*Sampler {
    if (app.cursor >= app.session.racks.items.len) return null;
    // zig fmt: off
    return switch (app.session.racks.items[app.cursor].instrument) {
        .sampler => |*s| s, else => null,
    };
}

/// The PolySynth on the cursor's track, or null.
pub fn cursorSynth(app: *App) ?*ws.dsp.PolySynth {
    if (app.cursor >= app.session.racks.items.len) return null;
    return switch (app.session.racks.items[app.cursor].instrument) {
        .poly_synth => |*s| s, else => null,
        // zig fmt: on
    };
}

/// The SoundfontPlayer on the cursor's track, or - if the soundfont editor
/// is open - the one being edited. Null when neither is a soundfont track.
/// Mirrors `cursorDrumMachine`'s two-fallback shape.
pub fn cursorSoundfont(app: *App) ?*ws.dsp.SoundfontPlayer {
    const t = cursorSoundfontTrack(app) orelse return null;
    return switch (app.session.racks.items[t].instrument) {
        .soundfont, .acoustic => |*sf| sf,
        else => null,
    };
}

/// The track `cursorSoundfont` resolves to. Both soundfont kinds share one
/// player and one editor, so the lookup is shared too; only `activeScope`
/// below cares which of the two it landed on.
pub fn cursorSoundfontTrack(app: *App) ?usize {
    if (app.cursor < app.session.racks.items.len) {
        switch (app.session.racks.items[app.cursor].instrument) {
            .soundfont, .acoustic => return app.cursor,
            else => {},
        }
    }
    if (app.view == .soundfont_editor and app.soundfont_track < app.session.racks.items.len) {
        switch (app.session.racks.items[app.soundfont_track].instrument) {
            .soundfont, .acoustic => return app.soundfont_track,
            else => {},
        }
    }
    return null;
}

/// The command-line Tab-completion gate (see cmd.Scope): reuses the exact
/// same track lookups the scoped commands themselves check at run time
/// (cursorDrumMachine/cursorSampler/cursorSynth), so what gets offered in
/// the popup always matches what would actually work if typed in full.
pub fn activeScope(app: *App) cmd_mod.Scope {
    if (cursorDrumMachine(app) != null) return .drum;
    if (cursorSampler(app) != null) return .sampler;
    if (cursorSynth(app) != null) return .synth;
    if (cursorSlicer(app) != null) return .slicer;
    if (cursorSoundfontTrack(app)) |t| {
        return if (app.session.racks.items[t].instrument == .acoustic) .acoustic else .soundfont;
    }
    return .any;
}

/// Appends " (genre1/genre2)" for the genre tags in `tags` (everything past
/// the always-present "wstudio" tag at index 0). Writes nothing if there are
/// no genre tags (e.g. the "init" preset).
pub fn writeGenres(w: *std.Io.Writer, tags: []const []const u8) std.Io.Writer.Error!void {
    if (tags.len <= 1) return;
    try w.writeAll(" (");
    try preset_ed.writeGenreTags(w, tags);
    try w.writeAll(")");
}

/// `:synth-preset [name]` - apply a factory patch (see `dsp/synth_presets.zig`)
/// or a user-saved one (see `tui/user_presets.zig`) to the cursor track's
/// synth. No args, or an unknown name, lists the available preset names
/// instead of guessing. User presets are checked first, so saving under a
/// factory name overrides it for `:synth-preset` (the factory list itself
/// is compiled-in and never touched).
pub fn cmdSynthPreset(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        for (app.user_synth_presets.items, 0..) |p, i| {
            if (i > 0) w.writeAll(", ") catch break;
            w.print("{s}*", .{p.name}) catch break;
        }
        for (ws.dsp.synth_presets.presets, 0..) |p, i| {
            if (i > 0 or app.user_synth_presets.items.len > 0) w.writeAll(", ") catch break;
            w.writeAll(p.name) catch break;
            writeGenres(&w, p.tags) catch break;
        }
        const marker: []const u8 = if (app.user_synth_presets.items.len > 0) " (* = saved)" else "";
        app.setStatus("synth presets{s}: {s}", .{ marker, w.buffered() });
        return;
    }
    const user = user_presets.find(app.user_synth_presets.items, trimmed);
    const factory = ws.dsp.synth_presets.find(trimmed);
    if (user == null and factory == null) {
        app.setStatus("synth-preset: unknown '{s}' - :synth-preset lists names", .{trimmed});
        return;
    }
    _ = cursorSynth(app) orelse {
        app.setStatus("synth-preset: select a synth track first", .{});
        return;
    };
    const rack = app.session.racks.items[app.cursor];
    const displaced = if (user) |preset|
        user_presets.apply(app.allocator, rack, preset, app.session.project.sample_rate) catch |e| {
            app.setStatus("synth-preset: {s}", .{@errorName(e)});
            return;
        }
    else
        ws.persist.applySynthPatch(app.allocator, rack, factory.?, app.session.project.sample_rate) catch |e| {
            app.setStatus("synth-preset: {s}", .{@errorName(e)});
            return;
        };
    app.session.syncTrackChain(@intCast(app.cursor), rack);
    app.session.retireFxChain(displaced);
    app.dirty = true;
    app.setStatus("synth preset: {s}", .{trimmed});
}

/// `:synth-preset-save <name>` - snapshot the cursor track's current synth
/// params (`PolySynth.toPatch`) and persist them under `name`, overwriting
/// any existing saved preset of the same name (case-insensitive).
pub fn cmdSynthPresetSave(app: *App, args: []const u8) void {
    const name = std.mem.trim(u8, args, " ");
    if (name.len == 0) {
        app.setStatus("usage: synth-preset-save <name>", .{});
        return;
    }
    const s = cursorSynth(app) orelse {
        app.setStatus("synth-preset-save: select a synth track first", .{});
        return;
    };
    const rack = app.session.racks.items[app.cursor];
    user_presets.upsert(app.allocator, app.io, &app.user_synth_presets, name, s.toPatch(), &rack.fx, app.session.project.sample_rate) catch |e| {
        app.setStatus("synth-preset-save: failed to save ({s})", .{@errorName(e)});
        return;
    };
    app.setStatus("saved synth preset: {s}", .{name});
}

/// `:drum-kit [name]` - regenerate all 8 pads of the cursor track's drum
/// machine from a procedural kit variant (see `dsp/drum_kit.zig`'s
/// `variants` table), or apply a user-saved kit's tuning (name/gain/pan/
/// pitch/ADSR/choke - see `tui/user_drum_kits.zig`) onto whatever's already
/// loaded there. No args, or an unknown name, lists the available names.
/// User kits are checked first, so saving under a factory name shadows it
/// for `:drum-kit` (the factory list itself is compiled-in and never
/// touched) - same precedence `:synth-preset` already established.
pub fn cmdDrumKit(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        for (app.user_drum_kits.items, 0..) |k, i| {
            if (i > 0) w.writeAll(", ") catch break;
            w.print("{s}*", .{k.name}) catch break;
        }
        for (ws.dsp.drum_kit.variants, 0..) |v, i| {
            if (i > 0 or app.user_drum_kits.items.len > 0) w.writeAll(", ") catch break;
            w.writeAll(v.name) catch break;
            writeGenres(&w, v.tags) catch break;
        }
        const marker: []const u8 = if (app.user_drum_kits.items.len > 0) " (* = saved)" else "";
        app.setStatus("drum kits{s}: {s}", .{ marker, w.buffered() });
        return;
    }
    const dm = cursorDrumMachine(app) orelse {
        app.setStatus("drum-kit: select a drum-machine track first", .{});
        return;
    };
    if (user_drum_kits.find(app.user_drum_kits.items, trimmed)) |kit| {
        dm.applyPadTune(&kit.pads);
        app.dirty = true;
        app.setStatus("drum kit (saved): {s}", .{trimmed});
        return;
    }
    const variant = for (&ws.dsp.drum_kit.variants) |*v| {
        if (std.ascii.eqlIgnoreCase(v.name, trimmed)) break v;
    } else {
        app.setStatus("drum-kit: unknown '{s}' - :drum-kit lists names", .{trimmed});
        return;
    };
    dm.loadKitVariant(variant) catch |e| {
        app.setStatus("drum-kit: {s}", .{@errorName(e)});
        return;
    };
    app.dirty = true;
    app.setStatus("drum kit: {s}", .{trimmed});
}

/// `:drum-kit-save <name>` - snapshot the cursor track's drum machine pads
/// 0-7's tuning (name/gain/pan/pitch/ADSR/choke-group - the same 8-pad
/// shape factory kits use) and persist it under `name`, overwriting any
/// existing saved kit of the same name (case-insensitive). No audio is
/// captured; see `tui/user_drum_kits.zig`'s own doc comment for why.
pub fn cmdDrumKitSave(app: *App, args: []const u8) void {
    const name = std.mem.trim(u8, args, " ");
    if (name.len == 0) {
        app.setStatus("usage: drum-kit-save <name>", .{});
        return;
    }
    const dm = cursorDrumMachine(app) orelse {
        app.setStatus("drum-kit-save: select a drum-machine track first", .{});
        return;
    };
    user_drum_kits.upsert(app.allocator, app.io, &app.user_drum_kits, name, dm.tunePads()) catch |e| {
        app.setStatus("drum-kit-save: failed to save ({s})", .{@errorName(e)});
        return;
    };
    app.setStatus("saved drum kit: {s}", .{name});
}

/// Load the kind of audio represented by the current view. Arrangement is
/// the one special case within an instrument scope: a sampler WAV becomes a
/// stamped whole clip there, while it replaces the playable sample elsewhere.
/// Public so empty editors can reuse this routing for enter.
pub fn cmdLoad(app: *App, args: []const u8) void {
    switch (app.view) {
        .arrangement => return cmdLoadClip(app, args),
        .synth_editor => return cmdLoadWavetable(app, args),
        .slicer_grid => return cmdLoadSlice(app, args),
        // The editor is shared by both soundfont kinds; only the .sf2 one
        // has a file to load, so let the scope switch below sort them out.
        .soundfont_editor => if (app.soundfont_track < app.session.racks.items.len and
            app.session.racks.items[app.soundfont_track].instrument == .soundfont)
        {
            return cmdLoadSoundfont(app, args);
        },
        else => {},
    }
    switch (activeScope(app)) {
        .drum, .sampler => cmdLoadSample(app, args),
        .synth => cmdLoadWavetable(app, args),
        .slicer => cmdLoadSlice(app, args),
        .soundfont => cmdLoadSoundfont(app, args),
        // Acoustic tracks play bundled banks only - there's no file to load,
        // so point at the two ways to pick one instead.
        .acoustic => app.setStatus("load: acoustic tracks pick a bundled bank - f: browse, or :library <name>", .{}),
        .any => app.setStatus("load: select an instrument track first", .{}),
    }
}

/// Sample loading targets the cursor pad on a drum-machine track or the
/// single Sampler on a sampler track. Drum wins if both somehow match, the
/// same precedence `activeScope` uses.
pub fn cmdLoadSample(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (cursorDrumMachine(app) != null) {
        const pad_idx: u8 = @intCast(app.drum_cursor[0]);
        if (trimmed.len == 0) {
            app.openBrowser(.{ .load_pad = pad_idx });
            return;
        }
        var path_buf: [path_buf_len]u8 = undefined;
        loadPadFromPath(app, pad_idx, expandHome(&path_buf, trimmed));
        return;
    }
    if (cursorSampler(app) == null) {
        app.setStatus("load: select a drum-machine or sampler track first", .{});
        return;
    }
    if (trimmed.len == 0) {
        app.openBrowser(.load_sample);
        return;
    }
    var path_buf: [path_buf_len]u8 = undefined;
    loadSampleFromPath(app, expandHome(&path_buf, trimmed));
}

/// The file browser's `p`: decode the WAV under the cursor into the engine's
/// off-mixer preview voice and play it, so a sample can be heard before it's
/// picked. Nothing about the project changes - no track, no dirty flag.
pub fn auditionPath(app: *App, path: []const u8) void {
    const data = readFileForLoad(app, path) orelse return;
    defer app.allocator.free(data);
    const stem = stemOf(path);
    app.session.engine.preview.loadWav(data, stem) catch |e| {
        app.setStatus("audition: {s}: {s}", .{ stem, @errorName(e) });
        return;
    };
    _ = app.session.engine.send(.preview_play);
    app.setStatus("audition: {s}", .{stem});
}

/// Shared by `:load <file>` and the file browser's sample-load
/// purpose (the browser hands over an already-resolved path - no `~` to
/// expand).
pub fn loadSampleFromPath(app: *App, path: []const u8) void {
    const track = app.cursor;
    const s = cursorSampler(app) orelse {
        app.setStatus("load: select a sampler track first", .{});
        return;
    };
    const data = readFileForLoad(app, path) orelse return;
    defer app.allocator.free(data);
    const stem = stemOf(path);
    var backup = history.captureTrackKindSwap(app, track) orelse {
        app.setStatus("load: out of memory", .{});
        return;
    };
    s.loadWav(data, stem) catch |e| {
        backup.deinit(app.allocator);
        app.setStatus("load: parse error: {s}", .{@errorName(e)});
        return;
    };
    s.pad.user_sample = true;
    history.push(app, backup);
    if (s.detectRootNote()) |r| {
        var nbuf: [8]u8 = undefined;
        app.setStatus("sample loaded: {s} (root {s} detected)", .{ stem, ws.midi.noteName(r.note, &nbuf) });
    } else {
        app.setStatus("sample loaded: {s}", .{stem});
    }
}

/// Which oscillator slot `:load` targets when invoked from inside
/// the synth editor: whichever section `app.synth_cursor` currently sits in
/// (the WAVETABLE section's own three rows included). Any other view (or an
/// unrecognized id) falls back to OSC A - the single-target convention
/// `:load` already uses for instruments with only one
/// possible destination.
pub fn oscSlotForCursor(id: u16) ws.dsp.PolySynth.OscSlot {
    return switch (id) {
        6...13, 43, 44, 186 => .b,
        50...58, 187 => .c,
        else => .a,
    };
}

pub fn cmdLoadWavetable(app: *App, args: []const u8) void {
    if (cursorSynth(app) == null) {
        app.setStatus("load: select a synth track first", .{});
        return;
    }
    const slot = if (app.view == .synth_editor)
        oscSlotForCursor(app.synth_cursor)
    else
        .a;
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        app.openBrowser(.{ .load_wavetable = slot });
        return;
    }
    var path_buf: [path_buf_len]u8 = undefined;
    loadWavetableFromPath(app, slot, expandHome(&path_buf, trimmed));
}

/// Shared by `:load <file>` and the file browser's wavetable-load
/// purpose (the browser hands over an already-resolved path - no `~` to
/// expand).
pub fn loadWavetableFromPath(app: *App, slot: ws.dsp.PolySynth.OscSlot, path: []const u8) void {
    const s = cursorSynth(app) orelse {
        app.setStatus("load: select a synth track first", .{});
        return;
    };
    const data = readFileForLoad(app, path) orelse return;
    defer app.allocator.free(data);
    s.loadWavetable(slot, data) catch |e| {
        app.setStatus("load: parse error: {s}", .{@errorName(e)});
        return;
    };
    app.dirty = true;
    app.setStatus("wavetable loaded into osc {s}: {s}", .{ @tagName(slot), std.fs.path.basename(path) });
}

/// The `.soundfont` player specifically - `.acoustic` shares the type but
/// plays bundled banks, so a .sf2 must never be loaded into one (see
/// cmdLibrary's mirror-image guard).
pub fn cursorSf2(app: *App) ?*ws.dsp.SoundfontPlayer {
    const track = cursorSoundfontTrack(app) orelse return null;
    return switch (app.session.racks.items[track].instrument) {
        .soundfont => |*sf| sf,
        else => null,
    };
}

pub fn cmdLoadSoundfont(app: *App, args: []const u8) void {
    if (cursorSf2(app) == null) {
        app.setStatus("load: select a soundfont track first", .{});
        return;
    }
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        app.openBrowser(.load_soundfont);
        return;
    }
    var path_buf: [path_buf_len]u8 = undefined;
    loadSoundfontFromPath(app, expandHome(&path_buf, trimmed));
}

/// Shared by `:load <file.sf2>` and the file browser's soundfont-load
/// purpose (the browser hands over an already-resolved path - no `~` to
/// expand).
pub fn loadSoundfontFromPath(app: *App, path: []const u8) void {
    const sf = cursorSf2(app) orelse {
        app.setStatus("load: select a soundfont track first", .{});
        return;
    };
    const data = readFileForLoad(app, path) orelse return;
    defer app.allocator.free(data);
    sf.loadSf2(data) catch |e| {
        app.setStatus("load: parse error: {s}", .{@errorName(e)});
        return;
    };
    app.dirty = true;
    if (sf.presetCount() == 0) {
        app.setStatus("soundfont loaded: {s} (no presets found)", .{std.fs.path.basename(path)});
    } else {
        app.setStatus("soundfont loaded: {s}  preset: {s}", .{ std.fs.path.basename(path), sf.presetName() });
    }
}

pub fn cmdLibrary(app: *App, args: []const u8) void {
    // Acoustic only: a fully-typed out-of-scope command still dispatches
    // (see cmd.Scope), and letting it push a bundled bank into a .sf2 track
    // would leave a SoundFont instrument playing content it can't browse.
    const track = cursorSoundfontTrack(app) orelse {
        app.setStatus("library: select an acoustic track first", .{});
        return;
    };
    const sf = switch (app.session.racks.items[track].instrument) {
        .acoustic => |*player| player,
        else => {
            app.setStatus("library: select an acoustic track first", .{});
            return;
        },
    };
    const name = std.mem.trim(u8, args, " ");
    const id = std.meta.stringToEnum(ws.dsp.builtin_library.Id, name) orelse {
        app.setStatus("usage: library <grand|upright|harpsichord>", .{});
        return;
    };
    sf.loadBuiltin(app.io, id) catch |err| {
        app.setStatus("library: {s}", .{@errorName(err)});
        return;
    };
    app.dirty = true;
    app.setStatus("library loaded: {s}", .{id.label()});
}

/// `:sf-preset <bank> <program>` - jump straight to a preset by its MIDI
/// bank/program pair, for users who already know the numbers rather than
/// stepping the PRESET param row one at a time.
pub fn cmdSfPreset(app: *App, args: []const u8) void {
    const sf = cursorSoundfont(app) orelse {
        app.setStatus("sf-preset: select a soundfont track first", .{});
        return;
    };
    var it = std.mem.tokenizeAny(u8, args, " ");
    const bank_s = it.next() orelse {
        app.setStatus("usage: sf-preset <bank> <program>", .{});
        return;
    };
    const program_s = it.next() orelse {
        app.setStatus("usage: sf-preset <bank> <program>", .{});
        return;
    };
    const bank = std.fmt.parseInt(u16, bank_s, 10) catch {
        app.setStatus("sf-preset: bank must be a number", .{});
        return;
    };
    const program = std.fmt.parseInt(u16, program_s, 10) catch {
        app.setStatus("sf-preset: program must be a number", .{});
        return;
    };
    if (!sf.selectBankProgram(bank, program)) {
        app.setStatus("sf-preset: no preset at bank {d} program {d}", .{ bank, program });
        return;
    }
    app.dirty = true;
    app.setStatus("preset: {s} (bank {d} program {d})", .{ sf.presetName(), bank, program });
}

pub fn cmdLoadClip(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        if (cursorSampler(app) == null) {
            app.setStatus("load: select a sampler track first", .{});
            return;
        }
        app.openBrowser(.load_clip);
        return;
    }
    var path_buf: [path_buf_len]u8 = undefined;
    loadClipFromPath(app, expandHome(&path_buf, trimmed));
}

/// Shared by `:load <file>` and the file browser's clip-load purpose.
/// "Audio clips" reuse the standalone Sampler + PatternPlayer wholesale
/// rather than a bespoke instrument: load the WAV, replace the track's live
/// pattern with one whole-clip note (Sampler ignores note-off, so the note
/// just needs to outlast the loop filter in `Session.rebuildSongData`), and
/// stamp it straight into the arrangement at the cursor bar, a one-command
/// "drop this audio on the timeline" instead of hand-placing a note and
/// stamping separately.
pub fn loadClipFromPath(app: *App, path: []const u8) void {
    const track = app.cursor;
    const s = cursorSampler(app) orelse {
        app.setStatus("load: select a sampler track first", .{});
        return;
    };
    const data = readFileForLoad(app, path) orelse return;
    defer app.allocator.free(data);
    const stem = stemOf(path);
    var backup = history.captureTrackKindSwap(app, track) orelse {
        app.setStatus("load: out of memory", .{});
        return;
    };
    s.loadWav(data, stem) catch |e| {
        backup.deinit(app.allocator);
        app.setStatus("load: parse error: {s}", .{@errorName(e)});
        return;
    };
    s.pad.user_sample = true;

    const bpm = @max(app.session.project.tempo_bpm, 1.0);
    const sr: f64 = @floatFromInt(app.session.project.sample_rate);
    const beats = @as(f64, @floatFromInt(s.pad.samples.len)) * bpm / (sr * 60.0);
    const length_beats = @max(beats, 1.0);
    const notes = [_]pattern_mod.Note{.{ .pitch = s.root_note, .start_beat = 0.0, .duration_beat = length_beats, .velocity = 1.0 }};
    app.session.racks.items[track].pattern_player.?.setNotes(&notes, length_beats);

    app.session.stampClipAtTick(track, app.arr_cursor_bar *| app.arr_grid.ticks()) catch {
        history.push(app, backup);
        app.dirty = true;
        app.setStatus("load: stamp failed; undo restores previous sample", .{});
        return;
    };
    history.push(app, backup);
    if (app.session.song_mode) app.session.rebuildSongData();

    app.dirty = true;
    app.setStatus("clip loaded: {s} ({d:.1} beats, bar {d})", .{ stem, length_beats, app.arr_cursor_bar +| 1 });
}

pub fn cmdLoadSlice(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        if (cursorSlicer(app) == null) {
            app.setStatus("load: select a slicer track first", .{});
            return;
        }
        app.openBrowser(.load_slice);
        return;
    }
    var path_buf: [path_buf_len]u8 = undefined;
    loadSliceFromPath(app, expandHome(&path_buf, trimmed));
}

/// Shared by `:load <file>` and the file browser's slice-load purpose.
/// `reset_slices = true` - an interactively-loaded clip's old slice
/// boundaries (fractions of the PREVIOUS clip's length) are meaningless
/// against new audio, so this always re-chops with a fresh `:slice`
/// afterward (unlike the session-restore path in persist.zig, which keeps
/// the saved boundaries - see `Slicer.loadWav`'s own doc comment).
pub fn loadSliceFromPath(app: *App, path: []const u8) void {
    const sl = cursorSlicer(app) orelse {
        app.setStatus("load: select a slicer track first", .{});
        return;
    };
    const data = readFileForLoad(app, path) orelse return;
    defer app.allocator.free(data);
    const stem = stemOf(path);
    sl.loadWav(data, stem, true) catch |e| {
        app.setStatus("load: parse error: {s}", .{@errorName(e)});
        return;
    };
    clampSlicerCursor(app, sl);
    app.dirty = true;
    app.setStatus("clip loaded: {s} - :slice <n> to chop it", .{stem});
}

pub fn cmdSlice(app: *App, args: []const u8) void {
    const track = cursorSlicerTrack(app) orelse {
        app.setStatus("slice: select a slicer track first", .{});
        return;
    };
    const sl = &app.session.racks.items[track].instrument.slicer;
    if (!sl.hasAudio()) {
        app.setStatus("slice: load audio first", .{});
        return;
    }
    const trimmed = std.mem.trim(u8, args, " ");
    const n = std.fmt.parseInt(u16, trimmed, 10) catch {
        app.setStatus("slice: usage :slice <1-{d}>", .{Slicer.max_slices});
        return;
    };
    if (n == 0) {
        app.setStatus("slice: usage :slice <1-{d}>", .{Slicer.max_slices});
        return;
    }
    history.recordSlicer(app, track);
    sl.sliceInto(@intCast(@min(n, Slicer.max_slices)));
    clampSlicerCursor(app, sl);
    app.dirty = true;
    app.setStatus("sliced into {d}", .{sl.slice_count});
}

/// `:chop [1-9]` - re-chop the loaded clip at detected transients. The
/// optional sensitivity defaults to 5; higher finds more (softer) hits.
pub fn cmdChop(app: *App, args: []const u8) void {
    const track = cursorSlicerTrack(app) orelse {
        app.setStatus("chop: select a slicer track first", .{});
        return;
    };
    const sl = &app.session.racks.items[track].instrument.slicer;
    if (!sl.hasAudio()) {
        app.setStatus("chop: load audio first", .{});
        return;
    }
    const trimmed = std.mem.trim(u8, args, " ");
    const sensitivity: u8 = if (trimmed.len == 0) 5 else std.fmt.parseInt(u8, trimmed, 10) catch 0;
    if (sensitivity < 1 or sensitivity > 9) {
        app.setStatus("chop: usage :chop [1-9] (sensitivity, default 5)", .{});
        return;
    }
    history.recordSlicer(app, track);
    const n = sl.chopTransients(sensitivity);
    clampSlicerCursor(app, sl);
    app.dirty = true;
    if (n <= 1)
        app.setStatus("chop: no transients found - try a higher sensitivity (:chop 1-9)", .{})
    else
        app.setStatus("chopped into {d} slices (sensitivity {d})", .{ n, sensitivity });
}

/// `:pad-len <n|off>` - give the cursor drum pad its own loop length, so it
/// wraps early and drifts against the rest of the pattern (Elektron's
/// per-track lengths). `off`, or any length at or past the pattern's own,
/// puts the row back on the pattern.
pub fn cmdPadLen(app: *App, args: []const u8) void {
    const track = cursorDrumTrack(app) orelse {
        app.setStatus("pad-len: select a drum track first", .{});
        return;
    };
    const dm = &app.session.racks.items[track].instrument.drum_machine;
    const pad: u8 = @intCast(app.drum_cursor[0]);
    const trimmed = std.mem.trim(u8, args, " ");
    const len: u16 = if (std.mem.eql(u8, trimmed, "off"))
        0
    else
        std.fmt.parseInt(u16, trimmed, 10) catch {
            app.setStatus("pad-len: usage :pad-len <1-{d}|off>", .{dm.step_count});
            return;
        };
    if (trimmed.len == 0) {
        app.setStatus("pad-len: usage :pad-len <1-{d}|off>", .{dm.step_count});
        return;
    }
    history.recordDrum(app, track);
    dm.setPadLen(pad, len);
    app.dirty = true;
    if (dm.pad_len[pad] == 0)
        app.setStatus("{s}: follows the pattern ({d} steps)", .{ dm.padName(pad), dm.step_count })
    else
        app.setStatus("{s}: loops over {d} of {d} steps", .{ dm.padName(pad), dm.pad_len[pad], dm.step_count });
}

/// `:bpm-sync [clip-bpm]` - fit the cursor track's clip to project tempo.
/// Slicers repitch, while standalone samplers warp to preserve pitch. With no
/// argument the clip's own tempo is detected (dsp/tempo.zig);
/// pass a number when the detector misses or the clip's real tempo is known.
/// Works on a slicer (every slice gets the same repitch, they share one clip)
/// and on a standalone sampler; a drum machine's pads are one-shots, not
/// loops, so there is nothing to fit there.
pub fn cmdBpmSync(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    const forced: ?f32 = if (trimmed.len == 0) null else parseFiniteFloat(f32, trimmed) catch {
        app.setStatus("bpm-sync: usage :bpm-sync [clip-bpm]", .{});
        return;
    };
    if (forced) |b| if (!(b > 0.0)) {
        app.setStatus("bpm-sync: clip BPM must be positive", .{});
        return;
    };

    const project_bpm: f32 = @floatCast(@max(app.session.project.tempo_bpm, 1.0));

    if (cursorSlicerTrack(app)) |track| {
        const sl = &app.session.racks.items[track].instrument.slicer;
        const clip_bpm = forced orelse blk: {
            const r = ws.dsp.tempo.detect(sl.samples, sl.sample_rate) orelse {
                if (tuneToProjectRoot(app, sl.samples, sl.sample_rate)) |semitones| {
                    history.recordSlicer(app, track);
                    sl.pitchAll(semitones);
                    app.dirty = true;
                    app.setStatus("sync: tune {d:.2} st; no clear pulse (pass BPM with :bpm-sync 174)", .{semitones});
                } else app.setStatus("bpm-sync: no clear pulse or pitch - pass BPM and set :scale", .{});
                return;
            };
            break :blk r.bpm;
        };
        const semitones = repitchToTempo(clip_bpm, project_bpm);
        history.recordSlicer(app, track);
        sl.stretchAll(1.0);
        sl.pitchAll(semitones);
        app.dirty = true;
        app.setStatus("sync: {d:.1} -> {d:.1} BPM, repitch {d:.2} st", .{ clip_bpm, project_bpm, semitones });
        return;
    }

    const track = resolveTrack(app);
    if (track < app.session.racks.items.len and
        app.session.racks.items[track].instrument == .sampler)
    {
        const smp = &app.session.racks.items[track].instrument.sampler;
        const clip_bpm = forced orelse blk: {
            const r = ws.dsp.tempo.detect(smp.pad.samples, smp.sample_rate) orelse {
                if (tuneToProjectRoot(app, smp.pad.samples, smp.sample_rate)) |semitones| {
                    history.recordParamSet(app, @intCast(track), ws.dsp.pad.pitch_id);
                    _ = app.session.engine.send(.{ .set_track_param_abs = .{
                        .track = @intCast(track),
                        .id = ws.dsp.pad.pitch_id,
                        .value = semitones,
                    } });
                    app.dirty = true;
                    app.setStatus("sync: tune {d:.2} st; no clear pulse (pass BPM with :bpm-sync 174)", .{semitones});
                } else app.setStatus("bpm-sync: no clear pulse or pitch - pass BPM and set :scale", .{});
                return;
            };
            break :blk r.bpm;
        };
        const ratio = ws.dsp.tempo.stretchToTempo(clip_bpm, project_bpm);
        const tune = tuneToProjectRoot(app, smp.pad.samples, smp.sample_rate);
        history.recordParamSet(app, @intCast(track), ws.dsp.pad.stretch_id);
        if (tune != null) history.recordParamSet(app, @intCast(track), ws.dsp.pad.pitch_id);
        _ = app.session.engine.send(.{ .set_track_param_abs = .{
            .track = @intCast(track),
            .id = ws.dsp.pad.stretch_id,
            .value = ratio,
        } });
        if (tune) |semitones| _ = app.session.engine.send(.{ .set_track_param_abs = .{
            .track = @intCast(track),
            .id = ws.dsp.pad.pitch_id,
            .value = semitones,
        } });
        app.dirty = true;
        if (tune) |semitones|
            app.setStatus("sync: {d:.1} -> {d:.1} BPM, tune {d:.2} st", .{ clip_bpm, project_bpm, semitones })
        else
            app.setStatus("sync: {d:.1} -> {d:.1} BPM (no project key or clear pitch)", .{ clip_bpm, project_bpm });
        return;
    }

    app.setStatus("bpm-sync: select a slicer or sampler track first", .{});
}

pub fn tuneToProjectRoot(app: *const App, samples: []const f32, sample_rate: u32) ?f32 {
    const scale = app.session.project.scale orelse return null;
    const detected = ws.dsp.pitch.detect(samples, sample_rate) orelse return null;
    return tuneToRoot(scale.root, detected);
}

pub fn repitchToTempo(clip_bpm: f32, project_bpm: f32) f32 {
    return -12.0 * @log2(ws.dsp.tempo.stretchToTempo(clip_bpm, project_bpm));
}

pub fn tuneToRoot(root: u4, detected: ws.dsp.pitch.Result) f32 {
    var delta = @as(i32, root) - @as(i32, detected.note % 12);
    if (delta > 6) delta -= 12;
    if (delta < -6) delta += 12;
    return @as(f32, @floatFromInt(delta)) - detected.cents / 100.0;
}

test "tuneToRoot takes shortest pitch-class shift and corrects cents" {
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), tuneToRoot(0, .{ .note = 70, .cents = 0 }), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -2.25), tuneToRoot(10, .{ .note = 60, .cents = 25 }), 1e-6);
}

test "repitchToTempo changes playback rate without warp" {
    try std.testing.expectApproxEqAbs(@as(f32, 12.0 * @log2(1.2)), repitchToTempo(100, 120), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), repitchToTempo(120, 120), 1e-6);
}

/// `:chop-random [n]` - Serato's "Set Random": chop into n slices at random
/// boundaries instead of transients or an even grid. Seeded off the frame
/// clock, so rolling it twice in a row gives two different chops.
pub fn cmdChopRandom(app: *App, args: []const u8) void {
    const track = cursorSlicerTrack(app) orelse {
        app.setStatus("chop-random: select a slicer track first", .{});
        return;
    };
    const sl = &app.session.racks.items[track].instrument.slicer;
    if (!sl.hasAudio()) {
        app.setStatus("chop-random: load audio first", .{});
        return;
    }
    const trimmed = std.mem.trim(u8, args, " ");
    const n: u16 = if (trimmed.len == 0) 8 else std.fmt.parseInt(u16, trimmed, 10) catch 0;
    if (n < 1 or n > Slicer.max_slices) {
        app.setStatus("chop-random: usage :chop-random [1-{d}] (default 8)", .{Slicer.max_slices});
        return;
    }
    history.recordSlicer(app, track);
    var prng = std.Random.DefaultPrng.init(@bitCast(@as(i64, @truncate(app.now_ns))));
    const made = sl.chopRandom(@intCast(n), prng.random());
    clampSlicerCursor(app, sl);
    app.dirty = true;
    app.setStatus("rolled {d} random slices", .{made});
}

fn clampSlicerCursor(app: *App, sl: *const Slicer) void {
    app.slicer_cursor[0] = @min(app.slicer_cursor[0], sl.slice_count -| 1);
}

/// `:spread [semitones]` - ramp playback pitch across a slicer's slices or a
/// drum machine's pads, one step per slot, so a single chop becomes playable
/// chromatically down the grid. Negative steps ramp down.
pub fn cmdSpread(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    const step: f32 = if (trimmed.len == 0) 1.0 else parseFiniteFloat(f32, trimmed) catch {
        app.setStatus("spread: usage :spread [semitones] (default 1)", .{});
        return;
    };
    if (cursorSlicerTrack(app)) |track| {
        const sl = &app.session.racks.items[track].instrument.slicer;
        history.recordSlicer(app, track);
        sl.spreadPitch(step);
        app.dirty = true;
        app.setStatus("spread {d:.2} st across {d} slices", .{ step, sl.slice_count });
        return;
    }
    if (cursorDrumTrack(app)) |track| {
        const dm = &app.session.racks.items[track].instrument.drum_machine;
        history.recordDrum(app, track);
        dm.spreadPitch(step);
        app.dirty = true;
        app.setStatus("spread {d:.2} st across the kit", .{step});
        return;
    }
    app.setStatus("spread: select a slicer or drum track first", .{});
}

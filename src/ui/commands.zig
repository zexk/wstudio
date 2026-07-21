//! The `:command` layer - every command-prompt action lives here, dispatched
//! through the `cmds` table by `run`. Handlers are free functions taking the
//! owning `*App`; they read/write App fields directly and call back into the
//! shared App helpers (`setStatus`, `doTrackAdd`, …) that the rest of the UI
//! also uses.

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
const spectrum_ed = @import("editors/spectrum.zig");
const theory = ws.theory;
const pattern_mod = ws.dsp.pattern;
const user_presets = @import("user_presets.zig");
const user_drum_kits = @import("user_drum_kits.zig");
const help_view = @import("help.zig");

fn wrap(comptime f: fn (*App, []const u8) void) *const fn (*anyopaque, []const u8) void {
    return struct {
        fn call(ctx: *anyopaque, args: []const u8) void {
            f(@ptrCast(@alignCast(ctx)), args);
        }
    }.call;
}

/// Big enough for any real filesystem path; see `expandHome`.
const path_buf_len: usize = 1024;

fn parseFiniteFloat(comptime T: type, text: []const u8) !T {
    const value = try std.fmt.parseFloat(T, text);
    if (!std.math.isFinite(value)) return error.InvalidCharacter;
    return value;
}

test "parseFiniteFloat rejects non-finite values" {
    try std.testing.expectApproxEqAbs(@as(f32, -1.25), try parseFiniteFloat(f32, "-1.25"), 1e-6);
    try std.testing.expectError(error.InvalidCharacter, parseFiniteFloat(f32, "nan"));
    try std.testing.expectError(error.InvalidCharacter, parseFiniteFloat(f64, "inf"));
    try std.testing.expectError(error.InvalidCharacter, parseFiniteFloat(f64, "-inf"));
}

/// Expand a leading `~` - the shell does this for CLI args, but paths typed
/// into the `:` prompt never pass through a shell. Handles bare `~` and
/// `~/rest`; `~otheruser` is left alone (not worth the /etc/passwd lookup for
/// a single-user TUI). Returns `path` unchanged when there's nothing to
/// expand, when $HOME isn't set, or when the expansion wouldn't fit `buf`.
/// $USERPROFILE is the fallback because Windows has no $HOME.
pub fn expandHome(buf: []u8, path: []const u8) []const u8 {
    if (path.len == 0 or path[0] != '~') return path;
    if (path.len > 1 and path[1] != '/') return path;
    const home = std.c.getenv("HOME") orelse std.c.getenv("USERPROFILE") orelse return path;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ std.mem.sliceTo(home, 0), path[1..] }) catch path;
}

// zig fmt: off
pub const cmds: []const cmd_mod.Def = &.{
    .{ .name = "q",           .desc = "quit (alias for :quit)",              .run = wrap(cmdQuit) },
    .{ .name = "quit",        .desc = "quit (refuses if unsaved changes)",   .run = wrap(cmdQuit) },
    .{ .name = "quit!",       .desc = "quit, discarding unsaved changes",    .run = wrap(cmdQuitForce) },
    .{ .name = "q!",          .desc = "quit, discarding unsaved changes (alias for :quit!)", .run = wrap(cmdQuitForce) },
    .{ .name = "qa",          .desc = "quit (alias for :quit)",              .run = wrap(cmdQuit) },
    .{ .name = "qa!",         .desc = "quit, discarding changes (alias for :quit!)", .run = wrap(cmdQuitForce) },
    .{ .name = "bpm",         .desc = "[<value>]  tempo in BPM (20–400)",    .run = wrap(cmdBpm) },
    .{ .name = "signature",   .desc = "[<n>[/4]]  time signature (1–16 beats per bar)", .run = wrap(cmdSig) },
    .{ .name = "sig",         .desc = "[<n>[/4]]  time signature (alias for :signature)", .run = wrap(cmdSig) },
    .{ .name = "gain",        .desc = "[<track>] [<dB>]  track gain (no track: cursor track)", .run = wrap(cmdGain) },
    .{ .name = "pan",         .desc = "[<track>] [<-1..1>]  track pan (no track: cursor track)", .run = wrap(cmdPan) },
    .{ .name = "volume",      .desc = "[<dB>]  master volume (–40 to +6)",   .run = wrap(cmdVol) },
    .{ .name = "vol",         .desc = "[<dB>]  master volume (alias for :volume)", .run = wrap(cmdVol) },
    .{ .name = "seek",        .desc = "<bar>  move playhead to bar",         .run = wrap(cmdSeek) },
    .{ .name = "pad-rename",  .desc = "<1-64> <name>  rename a loaded drum pad (up to 8 chars)", .run = wrap(cmdPadRename), .scope = .drum },
    .{ .name = "load",        .desc = "[file]  load the WAV/SF2 type for the current view and selected instrument; omit the file to browse", .run = wrap(cmdLoad) },
    .{ .name = "clap-instrument", .desc = "<plugin-id> <path>  load a CLAP instrument on the cursor track", .run = wrap(cmdClapInstrument) },
    .{ .name = "clap-fx",     .desc = "<plugin-id> <path>  append a CLAP effect to the cursor track", .run = wrap(cmdClapFx) },
    .{ .name = "clap-param",  .desc = "<1-based-index> [value]  inspect or set a CLAP instrument parameter", .run = wrap(cmdClapParam) },
    .{ .name = "sf-preset",   .desc = "<bank> <program>  jump to a SoundFont preset by its MIDI bank/program number", .run = wrap(cmdSfPreset), .scope = .soundfont },
    .{ .name = "slice",       .desc = "<n>  equal-divide the slicer's loaded clip into n slices (1-64)", .run = wrap(cmdSlice), .scope = .slicer },
    .{ .name = "chop",        .desc = "[1-9]  chop the slicer's clip at detected transients (sensitivity, default 5)", .run = wrap(cmdChop), .scope = .slicer },
    .{ .name = "edit",        .desc = "[file]  open a project (refuses if unsaved changes; omit the file to browse)", .run = wrap(cmdEdit) },
    .{ .name = "edit!",       .desc = "[file]  open a project, discarding changes; no file reverts the current one", .run = wrap(cmdEditForce) },
    .{ .name = "e",           .desc = "[file]  open a project (alias for :edit)", .run = wrap(cmdEdit) },
    .{ .name = "e!",          .desc = "[file]  open a project, discarding changes (alias for :edit!)", .run = wrap(cmdEditForce) },
    .{ .name = "restore-backup", .desc = "load the <project>~ autosave backup over the current session", .run = wrap(cmdRestoreBackup) },
    .{ .name = "new",         .desc = "start a blank project (refuses if unsaved changes)", .run = wrap(cmdNew) },
    .{ .name = "new!",        .desc = "start a blank project, discarding unsaved changes", .run = wrap(cmdNewForce) },
    .{ .name = "help",        .desc = "list all commands",                   .run = wrap(cmdHelp) },
    .{ .name = "h",           .desc = "list all commands (alias for :help)", .run = wrap(cmdHelp) },
    .{ .name = "track-add",   .desc = "[name]  add a synth track",           .run = wrap(cmdTrackAdd) },
    .{ .name = "track-del",   .desc = "[n]  delete track n (default: cursor)", .run = wrap(cmdTrackDel) },
    .{ .name = "d",           .desc = "[n]  delete track n (alias for :track-del)", .run = wrap(cmdTrackDel) },
    .{ .name = "track-rename",.desc = "[<n>] <name>  rename track n (no n: cursor track)", .run = wrap(cmdTrackRename) },
    .{ .name = "track-instrument", .desc = "<synth|sampler|drum|slicer|soundfont>  change the cursor track's instrument, keeping its notes where the old and new kinds are compatible", .run = wrap(cmdTrackInstrument) },
    .{ .name = "group-add",   .desc = "create an untitled track-grouping submix bus", .run = wrap(cmdGroupAdd) },
    .{ .name = "group-rename",.desc = "<n> <name>  rename group n", .run = wrap(cmdGroupRename) },
    .{ .name = "group-gain",  .desc = "<n> [<dB>]  group bus fader, post-FX (-60..12; no dB: report)", .run = wrap(cmdGroupGain) },
    .{ .name = "group-del",   .desc = "<n>  delete group n (members fall back to the master mix)", .run = wrap(cmdGroupDel) },
    .{ .name = "group-fx",    .desc = "<n>  open group n's FX chain", .run = wrap(cmdGroupFx) },
    .{ .name = "track-group", .desc = "<track> <group|none>  assign (or clear) which group a track submixes through", .run = wrap(cmdTrackGroup) },
    .{ .name = "write",       .desc = "[file]  save project (default: project.wsj)", .run = wrap(cmdSave) },
    .{ .name = "save",        .desc = "[file]  save project (alias for :write)",     .run = wrap(cmdSave) },
    .{ .name = "w",           .desc = "[file]  save project (alias for :write)",     .run = wrap(cmdSave) },
    .{ .name = "wa",          .desc = "[file]  save project (alias for :write)",     .run = wrap(cmdSave) },
    .{ .name = "write-quit",  .desc = "[file]  save project and quit",               .run = wrap(cmdWriteQuit) },
    .{ .name = "wq",          .desc = "[file]  save project and quit (alias for :write-quit)", .run = wrap(cmdWriteQuit) },
    .{ .name = "x",           .desc = "[file]  save project and quit (alias for :write-quit)", .run = wrap(cmdWriteQuit) },
    .{ .name = "wq!",         .desc = "[file]  save project and quit (alias for :write-quit)", .run = wrap(cmdWriteQuit) },
    .{ .name = "xa",          .desc = "[file]  save project and quit (alias for :write-quit)", .run = wrap(cmdWriteQuit) },
    .{ .name = "bounce",       .desc = "[file] [16|24]  render session to WAV (default: bounce.wav, 16-bit)", .run = wrap(cmdBounce) },
    .{ .name = "export",       .desc = "[file] [16|24]  render session to WAV (alias for :bounce)",          .run = wrap(cmdBounce) },
    .{ .name = "bounce-stems", .desc = "[dir] [16|24]  render each non-empty track soloed to <dir>/<track>.wav (default: stems/)", .run = wrap(cmdBounceStems) },
    .{ .name = "clear",       .desc = "erase all notes in the piano-roll pattern",          .run = wrap(cmdClear) },
    .{ .name = "%d",          .desc = "erase all notes in the pattern (alias for :clear)",  .run = wrap(cmdClear) },
    .{ .name = "humanize",    .desc = "[amount]  jitter the pattern's note timing/velocity 0-100% (default 15)", .run = wrap(cmdHumanize) },
    .{ .name = "swing",       .desc = "[percent]  piano-roll pattern swing 50-75% (default 50, straight) - matches the drum machine's", .run = wrap(cmdSwing) },
    .{ .name = "import-midi", .desc = "<file>  replace the pattern with a Standard MIDI File's notes",     .run = wrap(cmdImportMidi) },
    .{ .name = "export-midi", .desc = "<file>  write the pattern as a Standard MIDI File",                 .run = wrap(cmdExportMidi) },
    .{ .name = "metronome",   .desc = "[on|off]  toggle the click track",                   .run = wrap(cmdMetronome) },
    .{ .name = "scale",       .desc = "[<root> [<type>]|off]  piano-roll scale highlight + chord-stamp key", .run = wrap(cmdScale) },
    .{ .name = "ghost",       .desc = "[on|off]  dim every other melodic track's notes into the piano-roll background", .run = wrap(cmdGhost) },
    .{ .name = "synth-preset", .desc = "[name]  apply a factory or saved synth patch to the cursor track (no args: list names)", .run = wrap(cmdSynthPreset), .scope = .synth },
    .{ .name = "synth-preset-save", .desc = "<name>  save the cursor track's current synth params as a reusable preset", .run = wrap(cmdSynthPresetSave), .scope = .synth },
    .{ .name = "drum-kit",    .desc = "[name]  apply a factory or saved kit to the cursor drum machine (no args: list names)", .run = wrap(cmdDrumKit), .scope = .drum },
    .{ .name = "drum-kit-save", .desc = "<name>  save the cursor drum machine's pad tuning (name/gain/pan/pitch/ADSR/choke, no audio) as a reusable kit", .run = wrap(cmdDrumKitSave), .scope = .drum },
    .{ .name = "split-drums", .desc = "replace the drum machine with one sampler + MIDI track per loaded pad", .run = wrap(cmdSplitDrums), .scope = .drum },
    .{ .name = "euclid",      .desc = "<pulses> [rotation]  Euclidean rhythm across the cursor pad's lane (e.g. :euclid 3, :euclid 5 2)", .run = wrap(cmdEuclid), .scope = .drum },
    .{ .name = "rotate",      .desc = "<steps>  rotate the cursor pad's lane in time, wrapping (negative = earlier)", .run = wrap(cmdRotate), .scope = .drum },
    .{ .name = "undo",         .desc = "undo the last edit (alias for the u key)",   .run = wrap(cmdUndo) },
    .{ .name = "redo",         .desc = "redo the last undone edit (alias for the U key)", .run = wrap(cmdRedo) },
    .{ .name = "reload-config", .desc = "re-run init.lua (options, keymaps, user commands, theme)", .run = wrap(cmdReloadConfig) },
    .{ .name = "so",           .desc = "re-run init.lua (alias for :reload-config)", .run = wrap(cmdReloadConfig) },
    .{ .name = "colorscheme", .desc = "[name]  switch the running frontend's color theme now (no name: report it)", .run = wrap(cmdColorscheme) },
    .{ .name = "colo",        .desc = "[name]  switch the color theme (alias for :colorscheme)", .run = wrap(cmdColorscheme) },
    // zig fmt: on
};

/// Look up `text` in the command table and run it, reporting unknown commands
/// in the status line.
pub fn run(app: *App, text: []const u8) void {
    if (!cmd_mod.dispatch(app.allCmds(), app, text)) {
        app.setStatus("not a command: {s}  (try :help)", .{text});
    }
}

/// Vim-style quit guard: refuse while the session holds edits the project
/// file doesn't (`App.dirty`). :q! / :qa! force, ctrl-c always exits.
fn cmdQuit(app: *App, _: []const u8) void {
    if (app.dirty) {
        app.setStatus("unsaved changes - :write to save, :quit! to discard", .{});
        return;
    }
    app.deleteBackupIfPresent();
    app.should_quit = true;
}
// zig fmt: off

fn cmdQuitForce(app: *App, _: []const u8) void { app.should_quit = true; }

fn cmdEdit(app: *App, args: []const u8) void { editOrRevert(app, args, false); }
fn cmdEditForce(app: *App, args: []const u8) void { editOrRevert(app, args, true); }
// zig fmt: on

fn clapArgs(app: *App, args: []const u8, usage: []const u8) ?struct { id: []const u8, path: []const u8 } {
    const trimmed = std.mem.trim(u8, args, " ");
    const split = std.mem.indexOfScalar(u8, trimmed, ' ') orelse {
        app.setStatus("usage: {s}", .{usage});
        return null;
    };
    const id = trimmed[0..split];
    const path = std.mem.trim(u8, trimmed[split + 1 ..], " ");
    if (id.len == 0 or path.len == 0) {
        app.setStatus("usage: {s}", .{usage});
        return null;
    }
    return .{ .id = id, .path = path };
}

fn cmdClapInstrument(app: *App, args: []const u8) void {
    const parsed = clapArgs(app, args, ":clap-instrument <plugin-id> <path>") orelse return;
    var path_buf: [path_buf_len]u8 = undefined;
    const path = expandHome(&path_buf, parsed.path);
    const track = app.cursorTrack() orelse {
        app.setStatus("select a track first", .{});
        return;
    };
    app.session.setClapInstrument(track, path, parsed.id) catch |err| {
        app.setStatus("CLAP instrument: {s}", .{@errorName(err)});
        return;
    };
    app.dirty = true;
    app.setStatus("CLAP instrument loaded: {s}", .{parsed.id});
}

fn cmdClapFx(app: *App, args: []const u8) void {
    const parsed = clapArgs(app, args, ":clap-fx <plugin-id> <path>") orelse return;
    var path_buf: [path_buf_len]u8 = undefined;
    const path = expandHome(&path_buf, parsed.path);
    const track = app.cursorTrack() orelse {
        app.setStatus("select a track first", .{});
        return;
    };
    const rack = app.session.racks.items[track];
    const unit = rack.fx.insertClap(
        app.session.allocator,
        rack.fx.units.items.len,
        path,
        parsed.id,
        app.session.project.sample_rate,
    ) catch |err| {
        app.setStatus("CLAP effect: {s}", .{@errorName(err)});
        return;
    };
    if (unit.payload.clap.audio_inputs_count != 1) {
        rack.fx.remove(app.session.allocator, rack.fx.units.items.len - 1);
        app.setStatus("CLAP plugin has no stereo audio input", .{});
        return;
    }
    unit.payload.clap.attachTransport(&app.session.engine.transport);
    app.session.syncTrackChain(@intCast(track), rack);
    app.dirty = true;
    app.setStatus("CLAP effect loaded: {s}", .{parsed.id});
}

fn cmdClapParam(app: *App, args: []const u8) void {
    const track = app.cursorTrack() orelse {
        app.setStatus("select a track first", .{});
        return;
    };
    const plugin = switch (app.session.racks.items[track].instrument) {
        .clap => |plugin| plugin,
        else => {
            app.setStatus("cursor track is not a CLAP instrument", .{});
            return;
        },
    };
    var words = std.mem.tokenizeScalar(u8, args, ' ');
    const index_text = words.next() orelse {
        app.setStatus("CLAP instrument has {d} parameters", .{plugin.parameterCount()});
        return;
    };
    const one_based = std.fmt.parseInt(u32, index_text, 10) catch {
        app.setStatus("parameter index must be 1-{d}", .{plugin.parameterCount()});
        return;
    };
    if (one_based == 0 or one_based > plugin.parameterCount()) {
        app.setStatus("parameter index must be 1-{d}", .{plugin.parameterCount()});
        return;
    }
    const info = plugin.parameterInfo(one_based - 1) orelse {
        app.setStatus("plugin rejected parameter {d}", .{one_based});
        return;
    };
    if (words.next()) |value_text| {
        const value = parseFiniteFloat(f64, value_text) catch {
            app.setStatus("CLAP parameter value must be finite", .{});
            return;
        };
        const clamped = std.math.clamp(value, info.min_value, info.max_value);
        _ = app.session.engine.send(.{ .set_clap_param = .{
            .track = track,
            .target = plugin,
            .id = info.id,
            .cookie = info.cookie,
            .value = clamped,
        } });
        app.dirty = true;
        app.setStatus("CLAP param {d} queued: {d}", .{ one_based, clamped });
        return;
    }
    const value = plugin.parameterValue(info.id) orelse {
        app.setStatus("plugin rejected parameter {d}", .{one_based});
        return;
    };
    var value_buf: [128]u8 = undefined;
    const formatted = plugin.formatParameter(info.id, value, &value_buf) orelse
        std.fmt.bufPrint(&value_buf, "{d}", .{value}) catch "?";
    app.setStatus("{d}/{d} {s}: {s}", .{
        one_based,
        plugin.parameterCount(),
        std.mem.sliceTo(&info.name, 0),
        formatted,
    });
}

/// `:e <file>` swaps in a different project (refusing on unsaved changes,
/// like `:q`). `:e!` forces it; `:e!` alone (no path) reverts the current
/// project to its last-saved state, vim's plain-`:e!` convention. The actual
/// swap happens in `run()` - see `App.requestReload`.
fn editOrRevert(app: *App, args: []const u8, force: bool) void {
    const trimmed = std.mem.trim(u8, args, " ");
    // Browsing itself touches nothing - allowed even with unsaved changes,
    // so the picker still opens. But warn up front rather than let the
    // user hunt down a file only to be refused at selection (browserActivate
    // re-checks dirty there, since openBrowser can't know which file, if
    // any, they'll end up picking).
    if (trimmed.len == 0 and !force) {
        app.openBrowser(.open_project);
        if (app.dirty) app.setStatus("unsaved changes - :write to save, :edit! to discard", .{});
        return;
    }
    if (!force and app.dirty) {
        app.setStatus("unsaved changes - :write to save, :edit! to discard", .{});
        return;
    }
    var path_buf: [path_buf_len]u8 = undefined;
    const path: []const u8 = if (trimmed.len > 0)
        expandHome(&path_buf, trimmed)
    else
        app.projectPath() orelse {
            app.setStatus("edit!: no project loaded yet - :edit! needs a path", .{});
            return;
        };
    app.requestReload(path);
}

/// Load the `<project>~` autosave backup over the current session - see
/// the prompt `run()` sets at startup when it finds one newer than the
/// project file. Requires a known project path (same requirement the
/// backup itself has: `maybeAutosave` skips brand-new, path-less projects).
fn cmdRestoreBackup(app: *App, _: []const u8) void {
    // Same pathless fallback as App.backupPath: a never-saved session's
    // autosave lives next to :w's default target.
    const path = app.projectPath() orelse app.defaultProjectPath();
    var buf: [path_buf_len]u8 = undefined;
    const backup = std.fmt.bufPrint(&buf, "{s}~", .{path}) catch {
        app.setStatus("restore-backup: path too long", .{});
        return;
    };
    app.requestRestoreBackup(backup);
}
// zig fmt: off

fn cmdNew(app: *App, _: []const u8) void { newOrForce(app, false); }
fn cmdNewForce(app: *App, _: []const u8) void { newOrForce(app, true); }
// zig fmt: on

/// `:new` starts a blank session (refusing on unsaved changes); `:new!` forces
/// it. Same reload path as `:e` - see `App.requestReload`.
fn newOrForce(app: *App, force: bool) void {
    if (!force and app.dirty) {
        app.setStatus("unsaved changes - :write to save, :new! to discard", .{});
        return;
    }
    app.requestReload(null);
}

fn cmdClear(app: *App, _: []const u8) void {
    // In the piano roll, clear the pattern being edited; elsewhere, the
    // cursor track's pattern.
    const track: usize = if (app.view == .piano_roll) app.piano_track else app.cursor;
    if (track >= app.session.racks.items.len or
        app.session.racks.items[track].pattern_player == null)
    {
        app.setStatus("clear: no piano-roll pattern", .{});
        return;
    }
    const pp = &app.session.racks.items[track].pattern_player.?;
    const n = pp.note_count;
    history.recordMelodic(app, @intCast(track));
    pp.clearNotes();
    app.setStatus("cleared {d} notes", .{n});
    piano_ed.syncLinkedClip(app);
}

/// `:humanize [amount]` - jitters every note in the pattern's timing (±amount%
/// of one grid step) and velocity (±amount%, relative), 0-100 (default 15).
/// Same track-resolution rule as `:clear`.
fn cmdHumanize(app: *App, args: []const u8) void {
    const track: usize = if (app.view == .piano_roll) app.piano_track else app.cursor;
    if (track >= app.session.racks.items.len or
        app.session.racks.items[track].pattern_player == null)
    {
        app.setStatus("humanize: no piano-roll pattern", .{});
        return;
    }
    const trimmed = std.mem.trim(u8, args, " ");
    const amount: f64 = if (trimmed.len == 0) 15.0 else parseFiniteFloat(f64, trimmed) catch {
        app.setStatus("humanize: expected a percent, e.g. :humanize 15", .{});
        return;
    };
    if (amount < 0.0 or amount > 100.0) {
        app.setStatus("humanize: amount must be 0-100", .{});
        return;
    }
    const pp = &app.session.racks.items[track].pattern_player.?;
    history.recordMelodic(app, @intCast(track));
    const step_beats = 1.0 / @as(f64, @floatFromInt(app.pianoStepsPerBeat()));
    const seed: u64 = @truncate(@as(u96, @bitCast(app.now_ns)));
    pp.humanize(amount, step_beats, seed);
    app.setStatus("humanized {d} notes ({d:.0}%)", .{ pp.note_count, amount });
    piano_ed.syncLinkedClip(app);
}

/// `:swing [percent]` - sets the piano-roll pattern's swing, 50 (straight,
/// the default) to 75 (hardest shuffle) - the melodic counterpart to the
/// drum machine's `<`/`>` swing, so a melodic track can match a swung drum
/// groove. Same track-resolution rule as `:clear`/`:humanize`. With no args,
/// reports the current setting (matches `:scale`). Not undo-tracked - a
/// mixer-style live param, same as the drum machine's own swing.
fn cmdSwing(app: *App, args: []const u8) void {
    const track: usize = if (app.view == .piano_roll) app.piano_track else app.cursor;
    if (track >= app.session.racks.items.len or
        app.session.racks.items[track].pattern_player == null)
    {
        app.setStatus("swing: no piano-roll pattern", .{});
        return;
    }
    const pp = &app.session.racks.items[track].pattern_player.?;
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        app.setStatus("swing: {d:.0}%", .{pp.swing.load(.monotonic)});
        return;
    }
    const pct = parseFiniteFloat(f32, trimmed) catch {
        app.setStatus("swing: expected a percent, e.g. :swing 62", .{});
        return;
    };
    pp.setSwing(pct);
    app.setStatus("swing: {d:.0}%", .{pp.swing.load(.monotonic)});
}

/// `:import-midi <file>` - replace the piano-roll pattern with a Standard
/// MIDI File's notes (every track's events merged onto one timeline - see
/// midi_file.zig's doc comment). Same track-resolution rule as `:clear`.
/// Doesn't touch the project tempo - the file's own tempo is only reported
/// in the status line, since silently retiming the project on import would
/// surprise whoever's mid-session.
fn cmdImportMidi(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        app.setStatus("import-midi: usage :import-midi <file>", .{});
        return;
    }
    const track: usize = if (app.view == .piano_roll) app.piano_track else app.cursor;
    if (track >= app.session.racks.items.len or
        app.session.racks.items[track].pattern_player == null)
    {
        app.setStatus("import-midi: no piano-roll pattern", .{});
        return;
    }
    var path_buf: [path_buf_len]u8 = undefined;
    const path = expandHome(&path_buf, trimmed);
    const data = readFileForLoad(app, path) orelse return;
    defer app.allocator.free(data);
    const result = ws.midi_file.parse(app.allocator, data) catch |e| {
        app.setStatus("import-midi: parse error: {s}", .{@errorName(e)});
        return;
    };
    defer app.allocator.free(result.notes);

    const pp = &app.session.racks.items[track].pattern_player.?;
    history.recordMelodic(app, @intCast(track));
    pp.setNotes(result.notes, result.length_beats);
    piano_ed.syncLinkedClip(app);
    if (result.truncated)
        app.setStatus("imported {d} notes (capped at {d}) at {d:.0} BPM", .{ result.notes.len, pattern_mod.max_notes, result.tempo_bpm })
    else
        app.setStatus("imported {d} notes at {d:.0} BPM", .{ result.notes.len, result.tempo_bpm });
}

/// `:export-midi <file>` - write the piano-roll pattern as a format-0
/// Standard MIDI File at the project's tempo. Same track-resolution rule as
/// `:clear`/`:import-midi`.
fn cmdExportMidi(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        app.setStatus("export-midi: usage :export-midi <file>", .{});
        return;
    }
    const track: usize = if (app.view == .piano_roll) app.piano_track else app.cursor;
    if (track >= app.session.racks.items.len or
        app.session.racks.items[track].pattern_player == null)
    {
        app.setStatus("export-midi: no piano-roll pattern", .{});
        return;
    }
    const pp = &app.session.racks.items[track].pattern_player.?;
    var note_buf: [pattern_mod.max_notes]pattern_mod.Note = undefined;
    const count = pp.copyNotes(&note_buf);

    const bytes = ws.midi_file.write(app.allocator, note_buf[0..count], app.session.project.tempo_bpm) catch {
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
// zig fmt: off

fn cmdUndo(app: *App, _: []const u8) void { history.doUndo(app); }
fn cmdRedo(app: *App, _: []const u8) void { history.doRedo(app); }
// zig fmt: on

/// Only sets a flag - the actual re-source needs the live `Runtime` (not
/// reachable from a command handler) plus frontend-only follow-up (repaint
/// the GUI theme, reprogram the TUI's OSC palette); `run()` does both once
/// it notices `pending_config_reload`. See `App.afterConfigReload`.
fn cmdReloadConfig(app: *App, _: []const u8) void {
    app.pending_config_reload = true;
}

/// `:colorscheme [name]` (Neovim's command; `:colo` is its own real
/// abbreviation, kept here too). Scoped to whichever theme option the
/// running frontend actually reads - `gui_theme` or `tui_theme`, see
/// config.zig - and, unlike `:reload-config`, touches nothing else: no
/// re-source, no keymap/command/autocmd churn, matching how Neovim's
/// `:colorscheme` only ever touches highlighting. No name reports the
/// active one. `run()` does the actual repaint once it notices
/// `pending_colorscheme` - see `App.pending_colorscheme`'s doc comment.
fn cmdColorscheme(app: *App, args: []const u8) void {
    const rt = app.lua_runtime orelse return;
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        const current: []const u8 = switch (rt.frontend) {
            .gui => @tagName(rt.config.gui_theme),
            .tui => @tagName(rt.config.tui_theme),
        };
        app.setStatus("colorscheme: {s}", .{current});
        return;
    }
    switch (rt.frontend) {
        .gui => {
            const name = std.meta.stringToEnum(config_mod.GuiTheme, trimmed) orelse {
                app.setStatus("colorscheme: must be one of patina, patina_light, graphite, graphite_light, umbra", .{});
                return;
            };
            rt.config.gui_theme = name;
        },
        .tui => {
            const name = std.meta.stringToEnum(config_mod.TuiTheme, trimmed) orelse {
                app.setStatus("colorscheme: must be one of none, patina, patina_light, graphite, graphite_light, umbra", .{});
                return;
            };
            rt.config.tui_theme = name;
        },
    }
    app.pending_colorscheme = true;
    app.emitEvent(.{ .ColorScheme = .{ .name = trimmed } });
    app.setStatus("colorscheme: {s}", .{trimmed});
}

pub fn cmdHelp(app: *App, _: []const u8) void {
    const section: ?help_view.Section = switch (app.view) {
        .tracks => .tracks,
        .drum_grid => .drum_grid,
        .slicer_grid => .slicer_grid,
        .sampler_editor => .sampler_editor,
        .soundfont_editor => .soundfont_editor,
        .synth_editor, .synth_fx_picker => .synth_editor,
        .piano_roll => .piano_roll,
        .arrangement => .arrangement,
        .automation, .automation_param_picker => .automation,
        .track_spectrum, .master_spectrum, .group_spectrum, .fx_picker => .spectrum,
        // zig fmt: off
        .file_browser => .file_browser,
        .preset_picker => switch (app.preset_picker_kind) { .synth => .synth_editor, .drum => .drum_grid, .soundfont => .soundfont_editor },
        // zig fmt: on
        .help, .instrument_picker => null,
    };
    app.prev_view = app.view;
    app.help_scroll = help_view.scrollForSection(section, app.allCmds(), app.userKeymapsSlice());
    app.help_search_hit = null;
    app.view = .help;
}

fn cmdMetronome(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    const on = if (std.mem.eql(u8, trimmed, "on"))
        true
    else if (std.mem.eql(u8, trimmed, "off"))
        false
    else
        !app.session.metronome_enabled;
    app.session.setMetronome(on);
    app.setStatus("metronome {s}", .{if (on) "on" else "off"});
}

/// `:ghost [on|off]` - toggles dimmed "ghost notes" from every other melodic
/// track into the piano roll's background (see `App.piano_ghost`).
fn cmdGhost(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    const on = if (std.mem.eql(u8, trimmed, "on"))
        true
    else if (std.mem.eql(u8, trimmed, "off"))
        false
    else
        !app.piano_ghost;
    app.piano_ghost = on;
    app.setStatus("ghost notes {s}", .{if (on) "on" else "off"});
}

/// `:scale [<root> [<type>]|off]` - sets or clears the piano roll's active
/// scale (see `App.piano_scale`). With no args, reports the current setting.
/// `<type>` alone (root omitted) keeps the existing root, defaulting to C.
fn cmdScale(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        if (app.piano_scale) |s|
            app.setStatus("scale: {s} {s}", .{ theory.pitchClassName(s.root), s.kind.label() })
        else
            app.setStatus("scale: off", .{});
        return;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "off")) {
        app.piano_scale = null;
        app.setStatus("scale: off", .{});
        return;
    }
    var it = std.mem.splitScalar(u8, trimmed, ' ');
    const first = it.next().?;
    const rest = std.mem.trim(u8, it.rest(), " ");
    // A bare type name (e.g. `:scale dorian`) keeps the existing root.
    var root: u4 = if (app.piano_scale) |s| s.root else 0;
    var type_str: []const u8 = first;
    if (theory.ScaleType.parse(first) == null) {
        root = theory.parsePitchClass(first) orelse {
            app.setStatus("scale: unknown root or type '{s}'", .{first});
            return;
        };
        type_str = rest;
    }
    const kind: theory.ScaleType = if (type_str.len > 0)
        theory.ScaleType.parse(type_str) orelse {
            app.setStatus("scale: unknown type '{s}' (try major/minor/dorian/…)", .{type_str});
            return;
        }
    else if (app.piano_scale) |s|
        s.kind
    else
        .major;
    app.piano_scale = .{ .root = root, .kind = kind };
    app.setStatus("scale: {s} {s}", .{ theory.pitchClassName(root), kind.label() });
}

fn cmdTrackAdd(app: *App, args: []const u8) void {
    const name = std.mem.trim(u8, args, " ");
    app.doTrackAdd(if (name.len > 0) name else null);
}

fn cmdSplitDrums(app: *App, args: []const u8) void {
    if (std.mem.trim(u8, args, " ").len != 0) {
        app.setStatus("split-drums: takes no arguments", .{});
        return;
    }
    if (app.cursor >= app.session.racks.items.len) {
        app.setStatus("split-drums: select a drum track", .{});
        return;
    }
    const count = app.session.splitDrumTrack(app.cursor) catch |err| {
        app.setStatus("split-drums: {s}", .{@errorName(err)});
        return;
    };
    app.dirty = true;
    app.setStatus("split into {d} sampler tracks", .{count});
}

fn cmdTrackDel(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    const idx: usize = if (trimmed.len == 0) blk: {
        if (app.cursor >= app.session.project.tracks.items.len) {
            app.setStatus("track-del: cursor is on the master row - give a track number", .{});
            return;
        }
        break :blk app.cursor;
    } else blk: {
        const n = std.fmt.parseInt(usize, trimmed, 10) catch {
            app.setStatus("track-del: expected a track number", .{});
            return;
        };
        if (n == 0 or n > app.session.project.tracks.items.len) {
            app.setStatus("track-del: track must be 1–{d}", .{app.session.project.tracks.items.len});
            return;
        }
        break :blk n - 1;
    };
    app.doTrackDel(idx);
}

fn cmdTrackRename(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        app.setStatus("usage: track-rename <n> <name>", .{});
        return;
    }
    var it = std.mem.splitScalar(u8, trimmed, ' ');
    const first = it.next().?;
    const rest = std.mem.trim(u8, it.rest(), " ");

    // A single token that isn't a bare number is far more likely a
    // forgotten <name> than someone renaming a track to a numeral: treat
    // it as the new name for the cursor track - same "no index: act on
    // the selection" convenience gain/pan/eq now share.
    const first_is_number = if (std.fmt.parseInt(usize, first, 10)) |_| true else |_| false;
    if (rest.len == 0 and !first_is_number) {
        const idx = cursorTrackIdx(app) orelse {
            app.setStatus("track-rename: cursor is on the master row - give a track number", .{});
            return;
        };
        app.session.project.renameTrack(idx, first) catch {
            app.setStatus("out of memory", .{});
            return;
        };
        app.dirty = true;
        app.setStatus("track {d} renamed to \"{s}\"", .{ idx + 1, first });
        return;
    }

    if (rest.len == 0) {
        app.setStatus("usage: track-rename <n> <name>", .{});
        return;
    }
    const n = std.fmt.parseInt(usize, first, 10) catch {
        app.setStatus("track-rename: expected a track number", .{});
        return;
    };
    if (n == 0 or n > app.session.project.tracks.items.len) {
        app.setStatus("track-rename: track must be 1–{d}", .{app.session.project.tracks.items.len});
        return;
    }
    app.session.project.renameTrack(n - 1, rest) catch {
        app.setStatus("out of memory", .{});
        return;
    };
    app.dirty = true;
    app.setStatus("track {d} renamed to \"{s}\"", .{ n, rest });
}

/// Swap the cursor track's instrument kind. Unlike the instrument picker
/// (which only ever fires on a blank track), this runs on a live track and
/// asks `Session.changeInstrumentKind` to carry the notes over when the old
/// and new kinds are compatible - see that function's doc comment for
/// exactly which pairings qualify.
fn cmdTrackInstrument(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        app.setStatus("usage: track-instrument <synth|sampler|drum|slicer|soundfont>", .{});
        return;
    }
    const kind = app_mod.apiKindFromName(trimmed) orelse {
        app.setStatus("track-instrument: unknown kind '{s}' (synth/sampler/drum/slicer/soundfont)", .{trimmed});
        return;
    };
    const idx = cursorTrackIdx(app) orelse {
        app.setStatus("track-instrument: cursor is on the master row - select a track", .{});
        return;
    };
    if (std.meta.activeTag(app.session.racks.items[idx].instrument) == kind) {
        app.setStatus("track {d} is already {s}", .{ idx + 1, trimmed });
        return;
    }
    var backup = history.captureTrackKindSwap(app, idx);
    const preserved = app.session.changeInstrumentKind(idx, kind) catch |err| {
        if (backup) |*b| b.deinit(app.allocator);
        app.setStatus("track-instrument: {s}", .{@errorName(err)});
        return;
    };
    history.push(app, backup);
    app.dirty = true;
    if (preserved) {
        app.setStatus("track {d}: now {s} (notes kept)", .{ idx + 1, trimmed });
    } else {
        app.setStatus("track {d}: now {s} (no compatible mapping - notes cleared)", .{ idx + 1, trimmed });
    }
}

fn cmdGroupAdd(app: *App, args: []const u8) void {
    if (std.mem.trim(u8, args, " ").len != 0) {
        app.setStatus("usage: group-add", .{});
        return;
    }
    const name = "untitled group";
    const idx = app.session.addGroup(name) catch |err| {
        app.setStatus("group-add: {s}", .{switch (err) {
            error.GroupLimitReached => "bank full (8 groups)",
            error.OutOfMemory => "out of memory",
        }});
        return;
    };
    app.dirty = true;
    app.setStatus("group {d} \"{s}\" created", .{ idx + 1, name });
}

/// Group index from a 1-based command argument, or null with a status
/// message already set - shared by every `:group-*`/`:track-group` command
/// that takes one.
fn parseGroupArg(app: *App, name: []const u8, s: []const u8) ?u8 {
    const n = std.fmt.parseInt(u8, s, 10) catch {
        app.setStatus("{s}: expected a group number", .{name});
        return null;
    };
    if (n == 0 or n > ws.engine.max_groups) {
        app.setStatus("{s}: group must be 1–{d}", .{ name, ws.engine.max_groups });
        return null;
    }
    return n - 1;
}

fn cmdGroupRename(app: *App, args: []const u8) void {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, args, " "), ' ');
    const idx_str = it.next() orelse "";
    const name = std.mem.trim(u8, it.rest(), " ");
    if (idx_str.len == 0 or name.len == 0) {
        app.setStatus("usage: group-rename <n> <name>", .{});
        return;
    }
    const idx = parseGroupArg(app, "group-rename", idx_str) orelse return;
    if (app.session.groups[idx] == null) {
        app.setStatus("group-rename: group {d} doesn't exist", .{idx + 1});
        return;
    }
    app.session.renameGroup(idx, name) catch {
        app.setStatus("out of memory", .{});
        return;
    };
    app.dirty = true;
    app.setStatus("group {d} renamed to \"{s}\"", .{ idx + 1, name });
}

fn cmdGroupGain(app: *App, args: []const u8) void {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, args, " "), ' ');
    const idx_str = it.next() orelse "";
    if (idx_str.len == 0) {
        app.setStatus("usage: group-gain <n> [<dB>]", .{});
        return;
    }
    const idx = parseGroupArg(app, "group-gain", idx_str) orelse return;
    if (app.session.groups[idx] == null) {
        app.setStatus("group-gain: group {d} doesn't exist", .{idx + 1});
        return;
    }
    const db_str = std.mem.trim(u8, it.rest(), " ");
    if (db_str.len == 0) {
        app.setStatus("group {d} gain: {d:.1}dB", .{ idx + 1, app.session.groups[idx].?.gain_db });
        return;
    }
    const db = parseFiniteFloat(f32, db_str) catch {
        app.setStatus("group-gain: expected a dB value, e.g. :group-gain 1 -6", .{});
        return;
    };
    app.session.setGroupGain(idx, db);
    app.dirty = true;
    app.setStatus("group {d} gain: {d:.1}dB", .{ idx + 1, app.session.groups[idx].?.gain_db });
}

fn cmdGroupDel(app: *App, args: []const u8) void {
    const idx_str = std.mem.trim(u8, args, " ");
    if (idx_str.len == 0) {
        app.setStatus("usage: group-del <n>", .{});
        return;
    }
    const idx = parseGroupArg(app, "group-del", idx_str) orelse return;
    if (app.session.groups[idx] == null) {
        app.setStatus("group-del: group {d} doesn't exist", .{idx + 1});
        return;
    }
    if (app.view == .group_spectrum and app.eq_group == idx) app.view = .tracks;
    // Must run BEFORE deleteGroup frees the slot: the very next addGroup
    // can reuse `idx`, and any undo entry still naming it would otherwise
    // silently retarget onto the new group's chain.
    _ = history.dropGroupPending(app, idx);
    app.session.deleteGroup(idx);
    app.dirty = true;
    app.setStatus("group {d} deleted", .{idx + 1});
}

fn cmdGroupFx(app: *App, args: []const u8) void {
    const idx_str = std.mem.trim(u8, args, " ");
    if (idx_str.len == 0) {
        app.setStatus("usage: group-fx <n>", .{});
        return;
    }
    const idx = parseGroupArg(app, "group-fx", idx_str) orelse return;
    if (app.session.groups[idx] == null) {
        app.setStatus("group-fx: group {d} doesn't exist", .{idx + 1});
        return;
    }
    spectrum_ed.switchToGroup(app, idx);
}

fn cmdTrackGroup(app: *App, args: []const u8) void {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, args, " "), ' ');
    const track_str = it.next() orelse "";
    const group_str = std.mem.trim(u8, it.rest(), " ");
    if (track_str.len == 0 or group_str.len == 0) {
        app.setStatus("usage: track-group <track> <group|none>", .{});
        return;
    }
    const track_1 = std.fmt.parseInt(usize, track_str, 10) catch {
        app.setStatus("track-group: bad track number '{s}'", .{track_str});
        return;
    };
    if (track_1 == 0 or track_1 > app.session.project.tracks.items.len) {
        app.setStatus("track-group: track must be 1–{d}", .{app.session.project.tracks.items.len});
        return;
    }
    const track_idx = track_1 - 1;
    if (std.ascii.eqlIgnoreCase(group_str, "none")) {
        app.session.assignTrackGroup(track_idx, null);
        app.dirty = true;
        app.setStatus("track {d}: ungrouped", .{track_1});
        return;
    }
    const idx = parseGroupArg(app, "track-group", group_str) orelse return;
    if (app.session.groups[idx] == null) {
        app.setStatus("track-group: group {d} doesn't exist", .{idx + 1});
        return;
    }
    app.session.assignTrackGroup(track_idx, idx);
    app.dirty = true;
    app.setStatus("track {d} → group {d}", .{ track_1, idx + 1 });
}

fn cmdPadRename(app: *App, args: []const u8) void {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, args, " "), ' ');
    const pad_str = it.next() orelse {
        app.setStatus("usage: pad-rename <1-{d}> <name>", .{DrumMachine.max_pads});
        return;
    };
    const name = std.mem.trim(u8, it.rest(), " ");
    if (name.len == 0) {
        app.setStatus("usage: pad-rename <1-{d}> <name>", .{DrumMachine.max_pads});
        return;
    }
    const pad_num = std.fmt.parseInt(u8, pad_str, 10) catch {
        app.setStatus("pad-rename: bad pad index '{s}'", .{pad_str});
        return;
    };
    if (pad_num < 1 or pad_num > DrumMachine.max_pads) {
        app.setStatus("pad-rename: pad index must be 1-{d}", .{DrumMachine.max_pads});
        return;
    }
    const pad_idx = pad_num - 1;
    const dm = cursorDrumMachine(app) orelse {
        app.setStatus("pad-rename: select a drum-machine track first", .{});
        return;
    };
    if (dm.pads[pad_idx] == null) {
        app.setStatus("pad-rename: pad {d} is empty - :load it first", .{pad_num});
        return;
    }
    dm.pads[pad_idx].?.rename(name);
    app.dirty = true;
    app.setStatus("pad {d} renamed: {s}", .{ pad_num, dm.pads[pad_idx].?.clipName() });
}

/// Reads a `:load`-family source file, setting status and returning `null`
/// on failure. Shared by every `load*FromPath` handler below.
fn readFileForLoad(app: *App, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        app.io,
        path,
        app.allocator,
        .limited(64 * 1024 * 1024),
    ) catch |e| {
        app.setStatus("load: cannot read '{s}': {s}", .{ path, @errorName(e) });
        return null;
    };
}

/// The filename minus its extension, for status messages and clip naming.
fn stemOf(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    return if (std.mem.lastIndexOf(u8, basename, ".")) |dot| basename[0..dot] else basename;
}

/// Shared by `:load`'s drum-track branch and the file browser's
/// pad-load purpose (the browser hands over an already-resolved path - no
/// `~` to expand).
pub fn loadPadFromPath(app: *App, pad_idx: u8, path: []const u8) void {
    const data = readFileForLoad(app, path) orelse return;
    defer app.allocator.free(data);
    const dm = cursorDrumMachine(app) orelse {
        app.setStatus("load: select a drum-machine track first", .{});
        return;
    };
    const stem = stemOf(path);
    dm.loadPadWav(pad_idx, data, stem) catch |e| {
        app.setStatus("load: parse error: {s}", .{@errorName(e)});
        return;
    };
    dm.pads[pad_idx].?.pad.user_sample = true; // loadPadWav above materialized it
    app.dirty = true;
    app.setStatus("pad {d} loaded: {s}", .{ pad_idx + 1, stem });
}

/// The track index of the drum machine on the cursor's track, or - if the
/// drum grid is open - the one being edited. Null when neither is a drum
/// machine. The index (not just the `*DrumMachine`) is what undo snapshots
/// need, hence the split from `cursorDrumMachine`.
fn cursorDrumTrack(app: *App) ?u16 {
    if (app.cursor < app.session.racks.items.len) {
        switch (app.session.racks.items[app.cursor].instrument) {
            .drum_machine => return @intCast(app.cursor),
            else => {},
        }
    }
    if (app.view == .drum_grid and app.drum_track < app.session.racks.items.len) {
        switch (app.session.racks.items[app.drum_track].instrument) {
            .drum_machine => return @intCast(app.drum_track),
            else => {},
        }
    }
    return null;
}

/// The drum machine on the cursor's track, or - if the drum grid is open -
/// the one being edited. Null when neither is a drum machine.
fn cursorDrumMachine(app: *App) ?*DrumMachine {
    const track = cursorDrumTrack(app) orelse return null;
    return switch (app.session.racks.items[track].instrument) {
        .drum_machine => |*dm| dm,
        else => unreachable, // cursorDrumTrack only returns drum-machine tracks
    };
}

/// `:euclid <pulses> [rotation]` - replace the cursor pad's lane with a
/// Euclidean rhythm: `pulses` hits spread as evenly as possible across the
/// whole pattern, optionally rotated so the first hit lands `rotation` steps
/// in. E(3,8) is the tresillo, E(5,16) a classic hat groove.
fn cmdEuclid(app: *App, args: []const u8) void {
    const track = cursorDrumTrack(app) orelse {
        app.setStatus("euclid: select a drum-machine track first", .{});
        return;
    };
    const dm = cursorDrumMachine(app).?;
    var it = std.mem.tokenizeScalar(u8, args, ' ');
    const pulses_str = it.next() orelse {
        app.setStatus("usage: euclid <pulses> [rotation], e.g. :euclid 3 or :euclid 5 2", .{});
        return;
    };
    const pulses = std.fmt.parseInt(u16, pulses_str, 10) catch {
        app.setStatus("euclid: bad pulse count '{s}'", .{pulses_str});
        return;
    };
    const rotation: i32 = if (it.next()) |rot_str| std.fmt.parseInt(i32, rot_str, 10) catch {
        app.setStatus("euclid: bad rotation '{s}'", .{rot_str});
        return;
    } else 0;
    if (pulses > dm.step_count) {
        app.setStatus("euclid: at most {d} pulses fit this pattern", .{dm.step_count});
        return;
    }
    const pad: u8 = @intCast(app.drum_cursor[0]);
    history.push(app, history.captureDrum(app, track));
    dm.euclidPad(pad, pulses, rotation);
    app.setStatus("euclid {d}/{d} on pad {d} ({s})", .{ pulses, dm.step_count, pad + 1, dm.padName(pad) });
}

/// `:rotate <steps>` - rotate the cursor pad's lane in time (positive =
/// later, negative = earlier), wrapping at the pattern boundary. Hits keep
/// their velocity; only their grid position moves.
fn cmdRotate(app: *App, args: []const u8) void {
    const track = cursorDrumTrack(app) orelse {
        app.setStatus("rotate: select a drum-machine track first", .{});
        return;
    };
    const dm = cursorDrumMachine(app).?;
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        app.setStatus("usage: rotate <steps> (negative = earlier), e.g. :rotate 2", .{});
        return;
    }
    const delta = std.fmt.parseInt(i32, trimmed, 10) catch {
        app.setStatus("rotate: bad step count '{s}'", .{trimmed});
        return;
    };
    const pad: u8 = @intCast(app.drum_cursor[0]);
    history.push(app, history.captureDrum(app, track));
    dm.rotatePad(pad, delta);
    app.setStatus("rotated pad {d} ({s}) {s}{d} steps", .{ pad + 1, dm.padName(pad), if (delta >= 0) "+" else "", delta });
}

/// The standalone Sampler on the cursor's track, or null.
fn cursorSampler(app: *App) ?*Sampler {
    if (app.cursor >= app.session.racks.items.len) return null;
    // zig fmt: off
    return switch (app.session.racks.items[app.cursor].instrument) {
        .sampler => |*s| s, else => null,
    };
}

/// The PolySynth on the cursor's track, or null.
fn cursorSynth(app: *App) ?*ws.dsp.PolySynth {
    if (app.cursor >= app.session.racks.items.len) return null;
    return switch (app.session.racks.items[app.cursor].instrument) {
        .poly_synth => |*s| s, else => null,
        // zig fmt: on
    };
}

/// The track index of the slicer the command should act on: the cursor's
/// track, or - if the slicer grid is open - the one being edited. Null when
/// neither is a slicer. Mirrors `cursorDrumMachine`'s two-fallback shape.
fn cursorSlicerTrack(app: *App) ?u16 {
    if (app.cursor < app.session.racks.items.len and
        app.session.racks.items[app.cursor].instrument == .slicer)
        return @intCast(app.cursor);
    if (app.view == .slicer_grid and app.slicer_track < app.session.racks.items.len and
        app.session.racks.items[app.slicer_track].instrument == .slicer)
        return app.slicer_track;
    return null;
}

fn cursorSlicer(app: *App) ?*Slicer {
    const t = cursorSlicerTrack(app) orelse return null;
    return &app.session.racks.items[t].instrument.slicer;
}

/// The SoundfontPlayer on the cursor's track, or - if the soundfont editor
/// is open - the one being edited. Null when neither is a soundfont track.
/// Mirrors `cursorDrumMachine`'s two-fallback shape.
fn cursorSoundfont(app: *App) ?*ws.dsp.SoundfontPlayer {
    if (app.cursor < app.session.racks.items.len) {
        switch (app.session.racks.items[app.cursor].instrument) {
            .soundfont => |*sf| return sf,
            else => {},
        }
    }
    if (app.view == .soundfont_editor and app.soundfont_track < app.session.racks.items.len) {
        switch (app.session.racks.items[app.soundfont_track].instrument) {
            .soundfont => |*sf| return sf,
            else => {},
        }
    }
    return null;
}

/// The cursor's track index, or null when it's on the master row (or out
/// of range). Shared fallback for commands whose leading `<track>` arg is
/// now optional - same "no args: act on the selection" convenience
/// `:track-del`'s cursor fallback already established.
fn cursorTrackIdx(app: *App) ?usize {
    if (app.cursor >= app.session.project.tracks.items.len) return null;
    return app.cursor;
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
    if (cursorSoundfont(app) != null) return .soundfont;
    return .any;
}

/// Appends " (genre1/genre2)" for the genre tags in `tags` (everything past
/// the always-present "wstudio" tag at index 0). Writes nothing if there are
/// no genre tags (e.g. the "init" preset).
fn writeGenres(w: *std.Io.Writer, tags: []const []const u8) std.Io.Writer.Error!void {
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
fn cmdSynthPreset(app: *App, args: []const u8) void {
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
    const patch = user_presets.find(app.user_synth_presets.items, trimmed) orelse
        // zig fmt: off
        ws.dsp.synth_presets.find(trimmed) orelse {
            app.setStatus("synth-preset: unknown '{s}' - :synth-preset lists names", .{trimmed});
            return;
        };
        // zig fmt: on
    const s = cursorSynth(app) orelse {
        app.setStatus("synth-preset: select a synth track first", .{});
        return;
    };
    s.applyPatch(patch);
    app.dirty = true;
    app.setStatus("synth preset: {s}", .{trimmed});
}

/// `:synth-preset-save <name>` - snapshot the cursor track's current synth
/// params (`PolySynth.toPatch`) and persist them under `name`, overwriting
/// any existing saved preset of the same name (case-insensitive).
fn cmdSynthPresetSave(app: *App, args: []const u8) void {
    const name = std.mem.trim(u8, args, " ");
    if (name.len == 0) {
        app.setStatus("usage: synth-preset-save <name>", .{});
        return;
    }
    const s = cursorSynth(app) orelse {
        app.setStatus("synth-preset-save: select a synth track first", .{});
        return;
    };
    user_presets.upsert(app.allocator, app.io, &app.user_synth_presets, name, s.toPatch()) catch |e| {
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
fn cmdDrumKit(app: *App, args: []const u8) void {
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
fn cmdDrumKitSave(app: *App, args: []const u8) void {
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
fn cmdLoad(app: *App, args: []const u8) void {
    switch (app.view) {
        .arrangement => return cmdLoadClip(app, args),
        .synth_editor => return cmdLoadWavetable(app, args),
        .slicer_grid => return cmdLoadSlice(app, args),
        .soundfont_editor => return cmdLoadSoundfont(app, args),
        else => {},
    }
    switch (activeScope(app)) {
        .drum, .sampler => cmdLoadSample(app, args),
        .synth => cmdLoadWavetable(app, args),
        .slicer => cmdLoadSlice(app, args),
        .soundfont => cmdLoadSoundfont(app, args),
        .any => app.setStatus("load: select an instrument track first", .{}),
    }
}

/// Sample loading targets the cursor pad on a drum-machine track or the
/// single Sampler on a sampler track. Drum wins if both somehow match, the
/// same precedence `activeScope` uses.
fn cmdLoadSample(app: *App, args: []const u8) void {
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

/// Shared by `:load <file>` and the file browser's sample-load
/// purpose (the browser hands over an already-resolved path - no `~` to
/// expand).
pub fn loadSampleFromPath(app: *App, path: []const u8) void {
    const s = cursorSampler(app) orelse {
        app.setStatus("load: select a sampler track first", .{});
        return;
    };
    const data = readFileForLoad(app, path) orelse return;
    defer app.allocator.free(data);
    const stem = stemOf(path);
    s.loadWav(data, stem) catch |e| {
        app.setStatus("load: parse error: {s}", .{@errorName(e)});
        return;
    };
    s.pad.user_sample = true;
    app.dirty = true;
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
fn oscSlotForCursor(id: u8) ws.dsp.PolySynth.OscSlot {
    return switch (id) {
        6...13, 43, 44, 186 => .b,
        50...58, 187 => .c,
        else => .a,
    };
}

fn cmdLoadWavetable(app: *App, args: []const u8) void {
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

fn cmdLoadSoundfont(app: *App, args: []const u8) void {
    if (cursorSoundfont(app) == null) {
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
    const sf = cursorSoundfont(app) orelse {
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

/// `:sf-preset <bank> <program>` - jump straight to a preset by its MIDI
/// bank/program pair, for users who already know the numbers rather than
/// stepping the PRESET param row one at a time.
fn cmdSfPreset(app: *App, args: []const u8) void {
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

fn cmdLoadClip(app: *App, args: []const u8) void {
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
    s.loadWav(data, stem) catch |e| {
        app.setStatus("load: parse error: {s}", .{@errorName(e)});
        return;
    };
    s.pad.user_sample = true;

    const bpm = @max(app.session.project.tempo_bpm, 1.0);
    const sr: f64 = @floatFromInt(app.session.project.sample_rate);
    const beats = @as(f64, @floatFromInt(s.pad.samples.len)) * bpm / (sr * 60.0);
    const length_beats = @max(beats, 1.0);
    const notes = [_]pattern_mod.Note{.{ .pitch = s.root_note, .start_beat = 0.0, .duration_beat = length_beats }};
    app.session.racks.items[track].pattern_player.?.setNotes(&notes, length_beats);

    history.push(app, history.captureLane(app, @intCast(track)));
    app.session.stampClipAtTick(track, app.arr_cursor_bar * app.arr_grid.ticks()) catch {
        app.setStatus("load: stamp failed (out of memory)", .{});
        return;
    };
    if (app.session.song_mode) app.session.rebuildSongData();

    app.dirty = true;
    app.setStatus("clip loaded: {s} ({d:.1} beats, bar {d})", .{ stem, length_beats, app.arr_cursor_bar + 1 });
}

fn cmdLoadSlice(app: *App, args: []const u8) void {
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
    app.dirty = true;
    app.setStatus("clip loaded: {s} - :slice <n> to chop it", .{stem});
}

fn cmdSlice(app: *App, args: []const u8) void {
    const track = cursorSlicerTrack(app) orelse {
        app.setStatus("slice: select a slicer track first", .{});
        return;
    };
    const sl = &app.session.racks.items[track].instrument.slicer;
    const trimmed = std.mem.trim(u8, args, " ");
    const n = std.fmt.parseInt(u16, trimmed, 10) catch {
        app.setStatus("slice: usage :slice <1-{d}>", .{Slicer.max_slices});
        return;
    };
    if (n == 0) {
        app.setStatus("slice: usage :slice <1-{d}>", .{Slicer.max_slices});
        return;
    }
    history.push(app, history.captureSlicer(app, track));
    sl.sliceInto(@intCast(@min(n, Slicer.max_slices)));
    app.dirty = true;
    app.setStatus("sliced into {d}", .{sl.slice_count});
}

/// `:chop [1-9]` - re-chop the loaded clip at detected transients. The
/// optional sensitivity defaults to 5; higher finds more (softer) hits.
fn cmdChop(app: *App, args: []const u8) void {
    const track = cursorSlicerTrack(app) orelse {
        app.setStatus("chop: select a slicer track first", .{});
        return;
    };
    const sl = &app.session.racks.items[track].instrument.slicer;
    const trimmed = std.mem.trim(u8, args, " ");
    const sensitivity: u8 = if (trimmed.len == 0) 5 else std.fmt.parseInt(u8, trimmed, 10) catch 0;
    if (sensitivity < 1 or sensitivity > 9) {
        app.setStatus("chop: usage :chop [1-9] (sensitivity, default 5)", .{});
        return;
    }
    history.push(app, history.captureSlicer(app, track));
    const n = sl.chopTransients(sensitivity);
    app.dirty = true;
    if (n <= 1)
        app.setStatus("chop: no transients found - try a higher sensitivity (:chop 1-9)", .{})
    else
        app.setStatus("chopped into {d} slices (sensitivity {d})", .{ n, sensitivity });
}

/// Explicit :save argument (with `~` expanded), else the file the session
/// was loaded from / last saved to (already resolved - see `setProjectPath`),
/// else "project.wsj". Always copies into `buf` rather than returning
/// `app.projectPath()` directly: callers pass the result straight back into
/// `setProjectPath`, whose `@memcpy` panics ("arguments alias") if src and
/// dst are the same backing buffer - which `app.project_path_buf` is.
fn savePath(app: *App, args: []const u8, buf: []u8) []const u8 {
    const arg = std.mem.trim(u8, args, " ");
    if (arg.len > 0) return expandHome(buf, arg);
    const p = app.projectPath() orelse app.defaultProjectPath();
    const len = @min(p.len, buf.len);
    @memcpy(buf[0..len], p[0..len]);
    return buf[0..len];
}

fn cmdSave(app: *App, args: []const u8) void {
    var path_buf: [path_buf_len]u8 = undefined;
    const path = savePath(app, args, &path_buf);
    app.emitEvent(.{ .ProjectSavePre = .{ .path = path } });
    ws.persist.save(app.allocator, &app.session, app.io, path) catch |e| {
        app.setStatus("save: {s}: {s}", .{ path, @errorName(e) });
        return;
    };
    app.deleteBackupIfPresent(); // stale for the path we just moved off of
    app.setProjectPath(path);
    app.dirty = false;
    app.setStatus("saved: {s}", .{path});
    app.emitEvent(.{ .ProjectSavePost = .{ .path = path } });
}

/// Vim-style write-and-quit: save the project, then exit. Only quits when
/// the save succeeds so a failed write leaves the session intact.
fn cmdWriteQuit(app: *App, args: []const u8) void {
    var path_buf: [path_buf_len]u8 = undefined;
    const path = savePath(app, args, &path_buf);
    app.emitEvent(.{ .ProjectSavePre = .{ .path = path } });
    ws.persist.save(app.allocator, &app.session, app.io, path) catch |e| {
        app.setStatus("save: {s}: {s}", .{ path, @errorName(e) });
        return;
    };
    app.deleteBackupIfPresent(); // stale for the path we just moved off of
    app.setProjectPath(path);
    app.dirty = false;
    app.emitEvent(.{ .ProjectSavePost = .{ .path = path } });
    app.should_quit = true;
}

/// Splits a `:bounce`-family arg string into the leading path/dir (possibly
/// empty - caller supplies the default) and an optional trailing `16`/`24`
/// bit-depth token (default 16-bit).
fn parseBounceArgs(args: []const u8) struct { path: []const u8, bit_depth: ws.wav.BitDepth } {
    var trimmed = std.mem.trim(u8, args, " ");
    var bit_depth: ws.wav.BitDepth = .pcm16;
    if (std.mem.lastIndexOfScalar(u8, trimmed, ' ')) |sp| {
        const tail = std.mem.trim(u8, trimmed[sp + 1 ..], " ");
        if (std.mem.eql(u8, tail, "24")) {
            bit_depth = .pcm24;
            trimmed = std.mem.trim(u8, trimmed[0..sp], " ");
        } else if (std.mem.eql(u8, tail, "16")) {
            trimmed = std.mem.trim(u8, trimmed[0..sp], " ");
        }
    } else if (std.mem.eql(u8, trimmed, "24")) {
        bit_depth = .pcm24;
        trimmed = "";
    } else if (std.mem.eql(u8, trimmed, "16")) {
        trimmed = "";
    }
    return .{ .path = trimmed, .bit_depth = bit_depth };
}

const BounceRange = struct { start_frame: u64, total_frames: u64, has_loop_region: bool };

/// An armed A/B loop region bounces exactly that span (e.g. exporting one
/// section to try in another tool); otherwise song mode renders the whole
/// arrangement and pattern mode the longest loop. Both cases add a 2s tail
/// for reverb and release.
fn computeBounceRange(app: *App) BounceRange {
    const engine = app.session.engine;
    const sr = app.session.project.sample_rate;
    const loop = engine.transport;
    const has_loop_region = loop.loop_enabled and loop.loop_end_frames > loop.loop_start_frames;
    const start_frame: u64 = if (has_loop_region) loop.loop_start_frames else 0;
    const content_frames: u64 = if (has_loop_region) loop.loop_end_frames - loop.loop_start_frames else blk: {
        const max_beats = if (app.session.song_mode) inner: {
            break :inner @max(1.0, ws.time_grid.tickToBeat(app.session.arrangement.lengthTicks()));
        } else @max(1.0, app.contentBeats());
        break :blk @intFromFloat(engine.transport.framesPerBeat() * max_beats);
    };
    return .{
        .start_frame = start_frame,
        .total_frames = content_frames + types.secondsToFrames(2.0, sr),
        .has_loop_region = has_loop_region,
    };
}

/// Render the live session (patterns + synth params + drum grid) offline to
/// a PCM WAV (16-bit by default, 24-bit with a trailing `24` argument).
/// Length = the longest loop plus a 2s tail for reverb and release. The
/// realtime backend is parked for the duration so the UI thread can drive
/// the engine without racing the audio thread.
fn cmdBounce(app: *App, args: []const u8) void {
    var path_buf: [path_buf_len]u8 = undefined;
    const parsed = parseBounceArgs(args);
    const path = if (parsed.path.len > 0) expandHome(&path_buf, parsed.path) else "bounce.wav";
    const bit_depth = parsed.bit_depth;

    const engine = app.session.engine;
    const sr = app.session.project.sample_rate;
    const range = computeBounceRange(app);
    const buffer = app.allocator.alloc(
        types.Sample,
        @as(usize, @intCast(range.total_frames)) * engine_mod.channels,
    ) catch {
        app.setStatus("bounce: out of memory", .{});
        return;
    };
    defer app.allocator.free(buffer);

    if (!parkAudio(app)) {
        engine.bounce_active.store(false, .release);
        app.setStatus("bounce: audio thread did not park", .{});
        return;
    }
    renderBounce(app, buffer, range.start_frame);
    engine.bounce_active.store(false, .release);
    engine.bounce_parked.store(false, .release);

    const file = std.Io.Dir.cwd().createFile(app.io, path, .{}) catch |e| {
        app.setStatus("bounce: {s}: {s}", .{ path, @errorName(e) });
        return;
    };
    defer file.close(app.io);
    var fbuf: [8192]u8 = undefined;
    var fw = file.writer(app.io, &fbuf);
    ws.wav.write(&fw.interface, sr, engine_mod.channels, buffer, bit_depth) catch |e| {
        app.setStatus("bounce: write failed: {s}", .{@errorName(e)});
        return;
    };
    fw.interface.flush() catch {};

    if (range.has_loop_region) {
        app.setStatus("bounced {d:.1}s (loop region) -> {s}", .{ types.framesToSeconds(range.total_frames, sr), path });
    } else {
        app.setStatus("bounced {d:.1}s -> {s}", .{ types.framesToSeconds(range.total_frames, sr), path });
    }
}

/// Fills `buf` with `name` reduced to filesystem-safe characters (alnum,
/// space, `-`, `_`); anything else becomes `_`. Falls back to `track<N>`
/// (1-based) if that leaves nothing.
fn sanitizeStemName(buf: []u8, name: []const u8, index: usize) []const u8 {
    var len: usize = 0;
    for (name) |c| {
        if (len >= buf.len) break;
        buf[len] = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', ' ' => c,
            else => '_',
        };
        len += 1;
    }
    if (len == 0) return std.fmt.bufPrint(buf, "track{d}", .{index + 1}) catch buf[0..0];
    return buf[0..len];
}

/// `:bounce-stems [dir] [16|24]` - renders every non-empty track soloed in
/// turn to `<dir>/<track-name>.wav` (default dir: `stems/`), using the same
/// length/range rules as `:bounce` (armed loop region, else full song/
/// pattern). Solo state is restored exactly afterward, whatever it was
/// before this ran.
fn cmdBounceStems(app: *App, args: []const u8) void {
    var path_buf: [path_buf_len]u8 = undefined;
    const parsed = parseBounceArgs(args);
    const dir = if (parsed.path.len > 0) expandHome(&path_buf, parsed.path) else "stems";
    const bit_depth = parsed.bit_depth;

    const engine = app.session.engine;
    const sr = app.session.project.sample_rate;
    const range = computeBounceRange(app);
    const buffer = app.allocator.alloc(
        types.Sample,
        @as(usize, @intCast(range.total_frames)) * engine_mod.channels,
    ) catch {
        app.setStatus("bounce-stems: out of memory", .{});
        return;
    };
    defer app.allocator.free(buffer);

    std.Io.Dir.cwd().createDirPath(app.io, dir) catch |e| {
        app.setStatus("bounce-stems: {s}: {s}", .{ dir, @errorName(e) });
        return;
    };

    const tracks = app.session.project.tracks.items;
    const saved_solo = app.allocator.alloc(bool, tracks.len) catch {
        app.setStatus("bounce-stems: out of memory", .{});
        return;
    };
    defer app.allocator.free(saved_solo);
    for (tracks, 0..) |t, i| saved_solo[i] = t.soloed;
    defer for (tracks, 0..) |*t, i| {
        t.soloed = saved_solo[i];
        _ = engine.send(.{ .set_track_solo = .{ .track = @intCast(i), .soloed = saved_solo[i] } });
    };

    var stem_buf: [64]u8 = undefined;
    var file_path_buf: [path_buf_len]u8 = undefined;
    var rendered: usize = 0;
    for (tracks, 0..) |t, i| {
        if (std.meta.activeTag(app.session.racks.items[i].instrument) == .empty) continue;

        for (tracks, 0..) |*t2, j| {
            t2.soloed = (j == i);
            _ = engine.send(.{ .set_track_solo = .{ .track = @intCast(j), .soloed = t2.soloed } });
        }

        if (!parkAudio(app)) {
            engine.bounce_active.store(false, .release);
            app.setStatus("bounce-stems: audio thread did not park", .{});
            return;
        }
        renderBounce(app, buffer, range.start_frame);
        engine.bounce_active.store(false, .release);
        engine.bounce_parked.store(false, .release);

        const stem_name = sanitizeStemName(&stem_buf, t.name, i);
        const file_path = std.fmt.bufPrint(&file_path_buf, "{s}/{s}.wav", .{ dir, stem_name }) catch {
            app.setStatus("bounce-stems: path too long for track {d}", .{i + 1});
            continue;
        };
        const file = std.Io.Dir.cwd().createFile(app.io, file_path, .{}) catch |e| {
            app.setStatus("bounce-stems: {s}: {s}", .{ file_path, @errorName(e) });
            continue;
        };
        defer file.close(app.io);
        var fbuf: [8192]u8 = undefined;
        var fw = file.writer(app.io, &fbuf);
        ws.wav.write(&fw.interface, sr, engine_mod.channels, buffer, bit_depth) catch |e| {
            app.setStatus("bounce-stems: write failed for {s}: {s}", .{ stem_name, @errorName(e) });
            continue;
        };
        fw.interface.flush() catch {};
        rendered += 1;
    }

    if (rendered == 0) {
        app.setStatus("bounce-stems: no non-empty tracks to render", .{});
    } else {
        app.setStatus("bounce-stems: {d} track(s) -> {s}/", .{ rendered, dir });
    }
}

/// Signal the realtime backend to park and wait until it confirms. Returns
/// false on timeout - the caller must NOT touch the engine then, or the two
/// threads would call process() concurrently. (The TUI always runs a backend
/// - ALSA or Null - so the timeout only fires if that thread is wedged.)
fn parkAudio(app: *App) bool {
    const engine = app.session.engine;
    engine.bounce_parked.store(false, .release);
    engine.bounce_active.store(true, .release);
    const start = std.Io.Timestamp.now(app.io, .awake).nanoseconds;
    while (!engine.bounce_parked.load(.acquire)) {
        const elapsed = std.Io.Timestamp.now(app.io, .awake).nanoseconds - start;
        if (elapsed > 100 * std.time.ns_per_ms) return false;
        std.atomic.spinLoopHint();
    }
    return true;
}

/// Render the session from `start_frame` into `buffer` (interleaved stereo),
/// then restore the live transport position and playing state. Assumes the
/// caller owns the engine (audio thread parked).
pub fn renderBounce(app: *App, buffer: []types.Sample, start_frame: u64) void {
    const engine = app.session.engine;
    const was_playing = engine.transport.playing;
    const saved_pos = engine.transport.position_frames;
    // An armed A/B loop would otherwise wrap the render forever; the caller
    // has already turned an armed loop region into `start_frame` + a matching
    // buffer length, so straight-line render here always yields the right span.
    const was_looping = engine.transport.loop_enabled;
    engine.transport.loop_enabled = false;

    resetDevices(app);
    engine.limiter.reset();
    engine.transport.seekFrames(start_frame);
    engine.transport.play();

    const block = types.default_block_frames * engine_mod.channels;
    var offset: usize = 0;
    while (offset < buffer.len) {
        const end = @min(offset + block, buffer.len);
        engine.process(buffer[offset..end]);
        offset = end;
    }

    resetDevices(app);
    engine.limiter.reset();
    engine.transport.seekFrames(saved_pos);
    engine.transport.loop_enabled = was_looping;
    if (was_playing) engine.transport.play() else engine.transport.stop();
}

/// Clear every device's tails/voices/sequencer state across all racks.
fn resetDevices(app: *App) void {
    var buf: [ws.Rack.chain_cap]dsp.Device = undefined;
    for (app.session.racks.items) |rack| {
        for (rack.chain(&buf)) |dev| dev.reset();
    }
}

fn cmdBpm(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        app.setStatus("bpm: {d:.1}", .{app.session.project.tempo_bpm});
        return;
    }
    const bpm = parseFiniteFloat(f64, trimmed) catch {
        app.setStatus("bpm: expected a number, e.g. :bpm 140", .{});
        return;
    };
    if (bpm < 20.0 or bpm > 400.0) {
        app.setStatus("bpm: must be between 20 and 400", .{});
        return;
    }
    app.session.project.tempo_bpm = bpm;
    _ = app.session.engine.send(.{ .set_tempo = bpm });
    // The loop region is stored in bars; its frame mirror just moved.
    app.session.syncLoop();
    app.dirty = true;
    app.setStatus("bpm: {d:.1}", .{bpm});
}

/// `:sig [<n>[/4]]` - beats per bar. The beat unit is fixed at /4 (a beat is
/// always a quarter note, matching the 16th-note step grid everywhere).
fn cmdSig(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        app.setStatus("sig: {d}/4", .{app.session.project.beats_per_bar});
        return;
    }
    var it = std.mem.splitScalar(u8, trimmed, '/');
    const n = std.fmt.parseInt(u8, it.first(), 10) catch {
        app.setStatus("signature: expected beats per bar, e.g. :signature 3", .{});
        return;
    };
    if (it.next()) |unit| {
        if (!std.mem.eql(u8, unit, "4")) {
            app.setStatus("sig: only /4 signatures are supported", .{});
            return;
        }
        if (it.next() != null) {
            app.setStatus("signature: expected beats per bar, e.g. :signature 3/4", .{});
            return;
        }
    }
    if (n < 1 or n > 16) {
        app.setStatus("sig: beats per bar must be 1–16", .{});
        return;
    }
    app.session.project.beats_per_bar = n;
    _ = app.session.engine.send(.{ .set_time_signature = n });
    // Bar boundaries moved; refit the song timeline if it's driving playback,
    // and re-derive the loop region's frame mirror.
    if (app.session.song_mode) app.session.rebuildSongData();
    app.session.syncLoop();
    app.dirty = true;
    app.setStatus("sig: {d}/4", .{n});
}

fn cmdGain(app: *App, args: []const u8) void {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, args, " "), ' ');
    const track_str = it.next() orelse "";
    // No leading arg at all: fall back to the cursor track, same
    // convenience :track-del's cursor fallback already established.
    const track_idx: usize = if (track_str.len == 0)
        cursorTrackIdx(app) orelse {
            app.setStatus("usage: gain <track> [<dB>]", .{});
            return;
        }
    else blk: {
        const track_1 = std.fmt.parseInt(usize, track_str, 10) catch {
            app.setStatus("gain: bad track number '{s}'", .{track_str});
            return;
        };
        if (track_1 == 0 or track_1 > app.session.project.tracks.items.len) {
            app.setStatus("gain: track must be 1–{d}", .{app.session.project.tracks.items.len});
            return;
        }
        break :blk track_1 - 1;
    };
    const track_1 = track_idx + 1;
    const track = &app.session.project.tracks.items[track_idx];
    const db_str = std.mem.trim(u8, it.rest(), " ");
    if (db_str.len == 0) {
        app.setStatus("track {d} gain: {d:.1}dB", .{ track_1, track.gain_db });
        return;
    }
    const db = parseFiniteFloat(f32, db_str) catch {
        app.setStatus("gain: expected a dB value, e.g. :gain 2 -6", .{});
        return;
    };
    const clamped = std.math.clamp(db, -60.0, 12.0);
    track.gain_db = clamped;
    _ = app.session.engine.send(.{ .set_track_gain = .{
        .track = @intCast(track_idx),
        .gain = types.dbToGain(clamped),
    } });
    app.dirty = true;
    app.setStatus("track {d} gain: {d:.1}dB", .{ track_1, clamped });
}

fn cmdPan(app: *App, args: []const u8) void {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, args, " "), ' ');
    const track_str = it.next() orelse "";
    const track_idx: usize = if (track_str.len == 0)
        cursorTrackIdx(app) orelse {
            app.setStatus("usage: pan <track> [<-1..1>]", .{});
            return;
        }
    else blk: {
        const track_1 = std.fmt.parseInt(usize, track_str, 10) catch {
            app.setStatus("pan: bad track number '{s}'", .{track_str});
            return;
        };
        if (track_1 == 0 or track_1 > app.session.project.tracks.items.len) {
            app.setStatus("pan: track must be 1–{d}", .{app.session.project.tracks.items.len});
            return;
        }
        break :blk track_1 - 1;
    };
    const track_1 = track_idx + 1;
    const track = &app.session.project.tracks.items[track_idx];
    const val_str = std.mem.trim(u8, it.rest(), " ");
    if (val_str.len == 0) {
        // zig fmt: off
        const pct: i32 = @intFromFloat(@abs(track.pan) * 100.0);
        if (pct == 0) app.setStatus("track {d} pan: center", .{track_1})
        else if (track.pan < 0) app.setStatus("track {d} pan: L{d}%", .{ track_1, pct })
        else app.setStatus("track {d} pan: R{d}%", .{ track_1, pct });
        return;
    }
    const val = parseFiniteFloat(f32, val_str) catch {
        app.setStatus("pan: expected a value between -1.0 and 1.0", .{});
        return;
    };
    track.pan = std.math.clamp(val, -1.0, 1.0);
    _ = app.session.engine.send(.{ .set_track_pan = .{ .track = @intCast(track_idx), .pan = track.pan } });
    app.dirty = true;
    const pct: i32 = @intFromFloat(@abs(track.pan) * 100.0);
    if (pct == 0) app.setStatus("track {d} pan: center", .{track_1})
    else if (track.pan < 0) app.setStatus("track {d} pan: L{d}%", .{ track_1, pct })
    else app.setStatus("track {d} pan: R{d}%", .{ track_1, pct });
    // zig fmt: on
}

fn cmdSeek(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    const bar_1 = std.fmt.parseInt(u64, trimmed, 10) catch {
        app.setStatus("seek: expected a bar number, e.g. :seek 5", .{});
        return;
    };
    if (bar_1 == 0) {
        app.setStatus("seek: bar number starts at 1", .{});
        return;
    }
    const sr = @as(f64, @floatFromInt(app.session.project.sample_rate));
    const bpm = @max(app.session.project.tempo_bpm, 1.0);
    const beats_per_bar: f64 = @floatFromInt(app.session.project.beats_per_bar);
    const frames_per_bar: u64 = @intFromFloat(sr * 60.0 / bpm * beats_per_bar);
    const frames = std.math.mul(u64, bar_1 - 1, frames_per_bar) catch {
        app.setStatus("seek: bar number is too large", .{});
        return;
    };
    _ = app.session.engine.send(.{ .seek_frames = frames });
    app.setStatus("seek → bar {d}", .{bar_1});
}

fn cmdVol(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        const sign: []const u8 = if (app.master_gain_db >= 0) "+" else "";
        app.setStatus("master vol: {s}{d:.1}dB  ([ / ] to adjust)", .{ sign, app.master_gain_db });
        return;
    }
    const db = parseFiniteFloat(f32, trimmed) catch {
        app.setStatus("volume: expected a dB value, e.g. :volume -6", .{});
        return;
    };
    app.master_gain_db = std.math.clamp(db, -40.0, 6.0);
    _ = app.session.engine.send(.{ .set_master_gain = types.dbToGain(app.master_gain_db) });
    const sign: []const u8 = if (app.master_gain_db >= 0) "+" else "";
    app.setStatus("master vol: {s}{d:.1}dB", .{ sign, app.master_gain_db });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "expandHome expands ~ and ~/rest via $HOME; leaves other forms alone" {
    const testing = std.testing;
    const home_c = std.c.getenv("HOME") orelse return error.SkipZigTest;
    const home = std.mem.sliceTo(home_c, 0);

    var buf: [path_buf_len]u8 = undefined;
    try testing.expectEqualStrings(home, expandHome(&buf, "~"));

    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/song.wsj", .{home});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, expandHome(&buf, "~/song.wsj"));

    // Another user's home, and paths without a leading ~, pass through.
    try testing.expectEqualStrings("~otheruser/x", expandHome(&buf, "~otheruser/x"));
    try testing.expectEqualStrings("relative/path.wav", expandHome(&buf, "relative/path.wav"));
    try testing.expectEqualStrings("/abs/path.wav", expandHome(&buf, "/abs/path.wav"));
    try testing.expectEqualStrings("", expandHome(&buf, ""));

    // A buffer too small to hold the expansion falls back to the original.
    var tiny: [1]u8 = undefined;
    try testing.expectEqualStrings("~/song.wsj", expandHome(&tiny, "~/song.wsj"));
}

test ":save reports the expanded path, not the literal ~, on failure" {
    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    const home_c = std.c.getenv("HOME") orelse return error.SkipZigTest;
    const home = std.mem.sliceTo(home_c, 0);

    // A directory that doesn't exist under $HOME - save fails, but the
    // status must show where it actually tried to write.
    var cmd_buf: [80]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, ":save ~/__wstudio_missing__/p.wsj", .{});
    for (cmd) |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    const status = app.status_buf[0..app.status_len];
    try std.testing.expect(std.mem.indexOf(u8, status, home) != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "~") == null);
}

test ":synth-preset applies a factory patch to the cursor track's synth" {
    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    try app.session.setInstrument(0, .poly_synth);

    var cmd_buf: [80]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, ":synth-preset acid-bass", .{});
    for (cmd) |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);

    const s = &app.session.racks.items[0].instrument.poly_synth;
    const expected = ws.dsp.synth_presets.find("acid-bass").?;
    try std.testing.expectEqual(expected.voice_mode, s.voice_mode);
    try std.testing.expectApproxEqAbs(expected.filter_res, s.filter_res, 1e-6);
    try std.testing.expect(app.dirty);
}

test ":synth-preset with no args lists names without touching the synth" {
    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    try app.session.setInstrument(0, .poly_synth);

    var cmd_buf: [40]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, ":synth-preset", .{});
    for (cmd) |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);

    const status = app.status_buf[0..app.status_len];
    try std.testing.expect(std.mem.indexOf(u8, status, "init") != null);
    try std.testing.expect(!app.dirty);
}

test ":synth-preset-save persists a hand-tuned patch, then :synth-preset re-applies it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // $HOME redirected at a scratch dir so this never writes to the real
    // ~/.config/wstudio/synth_presets.json.
    try @import("json_store.zig").testRedirectHome(&tmp);

    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    try app.session.setInstrument(0, .poly_synth);

    // Hand-tune a param, then save it under a new name.
    const s = &app.session.racks.items[0].instrument.poly_synth;
    s.gain = 0.77;
    s.filter_cutoff = 1234.0;

    var save_buf: [64]u8 = undefined;
    const save_cmd = try std.fmt.bufPrint(&save_buf, ":synth-preset-save my-lead", .{});
    for (save_cmd) |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectEqual(@as(usize, 1), app.user_synth_presets.items.len);
    try std.testing.expectEqualStrings("my-lead", app.user_synth_presets.items[0].name);

    // Reset the live synth, then re-apply the saved preset by name.
    s.gain = 0.1;
    s.filter_cutoff = 99.0;
    var apply_buf: [64]u8 = undefined;
    const apply_cmd = try std.fmt.bufPrint(&apply_buf, ":synth-preset my-lead", .{});
    for (apply_cmd) |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.77), s.gain, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1234.0), s.filter_cutoff, 1e-3);

    // A fresh App reloads it from disk (persisted across "restarts").
    var app2 = try App.init(std.testing.allocator, std.testing.io);
    defer app2.deinit();
    try std.testing.expectEqual(@as(usize, 1), app2.user_synth_presets.items.len);
    try std.testing.expectEqualStrings("my-lead", app2.user_synth_presets.items[0].name);
}

test ":drum-kit regenerates the cursor drum machine's pads" {
    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    try app.session.setInstrument(0, .drum_machine);

    var cmd_buf: [40]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, ":drum-kit analog", .{});
    for (cmd) |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);

    const dm = &app.session.racks.items[0].instrument.drum_machine;
    try std.testing.expect(!dm.pads[0].?.pad.user_sample);
    try std.testing.expect(app.dirty);
    const status = app.status_buf[0..app.status_len];
    try std.testing.expect(std.mem.indexOf(u8, status, "analog") != null);
}

test ":load reports the expanded path on a missing file (drum track)" {
    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    try app.session.setInstrument(0, .drum_machine);
    const home_c = std.c.getenv("HOME") orelse return error.SkipZigTest;
    const home = std.mem.sliceTo(home_c, 0);

    var cmd_buf: [80]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, ":load ~/__wstudio_missing__.wav", .{});
    for (cmd) |c| app.handleKey(.{ .char = c }, 0);
    app.handleKey(.enter, 0);
    const status = app.status_buf[0..app.status_len];
    try std.testing.expect(std.mem.indexOf(u8, status, home) != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "~") == null);
}

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
const spectrum_ed = @import("editors/fx_editor.zig");
const theory = ws.theory;
const tuning_mod = ws.dsp.tuning;
const pattern_mod = ws.dsp.pattern;
const user_presets = @import("user_presets.zig");
const user_drum_kits = @import("user_drum_kits.zig");
const help_view = @import("help.zig");

const commands_util = @import("commands/util.zig");
const commands_pattern = @import("commands/pattern.zig");
const commands_tracks = @import("commands/tracks.zig");
const commands_load = @import("commands/load.zig");
const commands_mixer = @import("commands/mixer.zig");

fn wrap(comptime f: fn (*App, []const u8) void) *const fn (*anyopaque, []const u8) void {
    return struct {
        fn call(ctx: *anyopaque, args: []const u8) void {
            f(@ptrCast(@alignCast(ctx)), args);
        }
    }.call;
}

/// Big enough for any real filesystem path; see `expandHome`.
pub const path_buf_len: usize = 1024;

pub fn parseFiniteFloat(comptime T: type, text: []const u8) !T {
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
    .{ .name = "bpm",         .desc = "[<value>]  tempo in BPM (20–400)",    .run = wrap(commands_mixer.cmdBpm) },
    .{ .name = "signature",   .desc = "[<n>/<d>]  base time signature", .run = wrap(commands_mixer.cmdSig) },
    .{ .name = "tempo-point", .desc = "<beat> <bpm> [step|ramp]  add tempo-map point", .run = wrap(commands_mixer.cmdTempoPoint) },
    .{ .name = "meter-point", .desc = "<beat> <n>/<d>  add meter-map point", .run = wrap(commands_mixer.cmdMeterPoint) },
    .{ .name = "automation-point", .desc = "<master|group:n|send:t:s> <beat> <dB> [linear|hold|ease]", .run = wrap(commands_mixer.cmdAutomationPoint) },
    .{ .name = "automation-mode", .desc = "[off|write|touch|latch]  automation capture mode", .run = wrap(commands_mixer.cmdAutomationMode) },
    .{ .name = "gain",        .desc = "[<track>] [<dB>]  track gain (no track: cursor track)", .run = wrap(commands_mixer.cmdGain) },
    .{ .name = "pan",         .desc = "[<track>] [<-1..1>]  track pan (no track: cursor track)", .run = wrap(commands_mixer.cmdPan) },
    .{ .name = "unmute",      .desc = "clear mute on every track (m toggles one track at a time)", .run = wrap(commands_mixer.cmdUnmute) },
    .{ .name = "unsolo",      .desc = "clear solo on every track (S toggles one track at a time)", .run = wrap(commands_mixer.cmdUnsolo) },
    .{ .name = "volume",      .desc = "[<dB>]  master volume (–40 to +6)",   .run = wrap(commands_mixer.cmdVol) },
    .{ .name = "seek",        .desc = "<bar>  move playhead to bar",         .run = wrap(commands_mixer.cmdSeek) },
    .{ .name = "section",     .desc = "<name>  add or rename section at arrangement cursor", .run = wrap(commands_mixer.cmdSection) },
    .{ .name = "section-del", .desc = "delete section at arrangement cursor", .run = wrap(commands_mixer.cmdSectionDel) },
    .{ .name = "clip-gain",   .desc = "[<dB>]  audio-region gain at arrangement cursor (-60..24)", .run = wrap(commands_mixer.cmdClipGain) },
    .{ .name = "clip-fade",   .desc = "[<in-seconds> <out-seconds> [linear|equal_power]]  audio-region edge fades", .run = wrap(commands_mixer.cmdClipFade) },
    .{ .name = "clip-stretch", .desc = "[<ratio>]  audio-region time stretch (0.125 to 8)", .run = wrap(commands_mixer.cmdClipStretch) },
    .{ .name = "clip-reverse", .desc = "toggle reversed audio-region playback", .run = wrap(commands_mixer.cmdClipReverse) },
    .{ .name = "clip-slip",   .desc = "<signed-seconds>  move audio inside its region", .run = wrap(commands_mixer.cmdClipSlip) },
    .{ .name = "clip-layer",  .desc = "[<0-255>]  inspect or set arrangement clip layer", .run = wrap(commands_mixer.cmdClipLayer) },
    .{ .name = "crossfade",   .desc = "crossfade overlapping audio layers at cursor", .run = wrap(commands_mixer.cmdCrossfade) },
    .{ .name = "consolidate", .desc = "render cursor audio region edits into one source", .run = wrap(commands_mixer.cmdConsolidate) },
    .{ .name = "take",        .desc = "[next|prev]  cycle alternate recordings on audio region", .run = wrap(commands_mixer.cmdTake) },
    .{ .name = "comp",        .desc = "<take> <start-beat> <end-beat>  splice alternate take range", .run = wrap(commands_mixer.cmdComp) },
    .{ .name = "load",        .desc = "[file]  load the WAV/SF2 type for the current view and selected instrument; omit the file to browse", .run = wrap(commands_load.cmdLoad) },
    .{ .name = "clap-instrument", .desc = "<plugin-id> <path>  load a CLAP instrument on the cursor track", .run = wrap(cmdClapInstrument) },
    .{ .name = "clap-fx",     .desc = "<plugin-id> <path>  append a CLAP effect to the cursor track", .run = wrap(cmdClapFx) },
    .{ .name = "clap-param",  .desc = "<1-based-index> [value]  inspect or set a CLAP instrument parameter", .run = wrap(cmdClapParam) },
    .{ .name = "clap-gui",    .desc = "toggle the current CLAP instrument or focused effect's native GUI", .run = wrap(cmdClapGui) },
    .{ .name = "vst3-gui",    .desc = "toggle the current VST3 instrument or focused effect's native GUI", .run = wrap(cmdVst3Gui) },
    .{ .name = "sf-preset",   .desc = "<bank> <program>  jump to a SoundFont preset by its MIDI bank/program number", .run = wrap(commands_load.cmdSfPreset), .scope = .{ .soundfont = true } },
    .{ .name = "library",     .desc = "<grand|upright|harpsichord>  load a bundled VCSL acoustic instrument", .run = wrap(commands_load.cmdLibrary), .scope = .{ .acoustic = true } },
    .{ .name = "slice",       .desc = "<n>  equal-divide the slicer's loaded clip into n slices (1-64)", .run = wrap(commands_load.cmdSlice), .scope = .{ .slicer = true } },
    .{ .name = "chop",        .desc = "[1-9]  chop the slicer's clip at detected transients (sensitivity, default 5)", .run = wrap(commands_load.cmdChop), .scope = .{ .slicer = true } },
    .{ .name = "chop-random", .desc = "[n]  roll the dice: chop the slicer's clip into n uneven slices (default 8)", .run = wrap(commands_load.cmdChopRandom), .scope = .{ .slicer = true } },
    .{ .name = "bpm-sync",    .desc = "[clip-bpm]  warp the clip to project tempo, tune it to the project key", .run = wrap(commands_load.cmdBpmSync), .scope = cmd_mod.scopes.sampler_slicer },
    .{ .name = "spread",      .desc = "[semitones]  ramp pitch across the slices/pads, one step each (default 1)", .run = wrap(commands_load.cmdSpread), .scope = cmd_mod.scopes.drum_slicer },
    .{ .name = "pad-len",     .desc = "<n|off>  loop the cursor drum pad over its own n steps (polymeter)", .run = wrap(commands_load.cmdPadLen), .scope = .{ .drum = true } },
    .{ .name = "edit",        .desc = "[file]  open a project (refuses if unsaved changes; omit the file to browse)", .run = wrap(cmdEdit) },
    .{ .name = "edit!",       .desc = "[file]  open a project, discarding changes; no file reverts the current one", .run = wrap(cmdEditForce) },
    .{ .name = "e",           .desc = "[file]  open a project (alias for :edit)", .run = wrap(cmdEdit) },
    .{ .name = "e!",          .desc = "[file]  open a project, discarding changes (alias for :edit!)", .run = wrap(cmdEditForce) },
    .{ .name = "recent",      .desc = "open a picker of the 10 most recently loaded or saved projects", .run = wrap(cmdRecent) },
    .{ .name = "restore-backup", .desc = "load the <project>~ autosave backup over the current session", .run = wrap(cmdRestoreBackup) },
    .{ .name = "new",         .desc = "start a blank project (refuses if unsaved changes)", .run = wrap(cmdNew) },
    .{ .name = "new!",        .desc = "start a blank project, discarding unsaved changes", .run = wrap(cmdNewForce) },
    .{ .name = "help",        .desc = "list all commands",                   .run = wrap(cmdHelp) },
    .{ .name = "track-add",   .desc = "[name]  add a synth track",           .run = wrap(commands_tracks.cmdTrackAdd) },
    .{ .name = "track-del",   .desc = "[n]  delete track n (default: cursor)", .run = wrap(commands_tracks.cmdTrackDel) },
    .{ .name = "rename",      .desc = "[<n>] <name>  rename what the open editor is editing - a drum pad, a slicer/sampler clip, a group (cursor on a group row), else a track; n picks a different pad or track", .run = wrap(commands_tracks.cmdRename) },
    .{ .name = "track-instrument", .desc = "[<n>] <synth|sampler|drum|slicer|soundfont|acoustic>  change track n's instrument, keeping its notes where the old and new kinds are compatible (no n: cursor track)", .run = wrap(commands_tracks.cmdTrackInstrument) },
    .{ .name = "group-add",   .desc = "create an untitled track-grouping submix bus", .run = wrap(commands_tracks.cmdGroupAdd) },
    .{ .name = "group-gain",  .desc = "<n> [<dB>]  group bus fader, post-FX (-60..12; no dB: report)", .run = wrap(commands_tracks.cmdGroupGain) },
    .{ .name = "group-del",   .desc = "<n>  delete group n (members fall back to the master mix)", .run = wrap(commands_tracks.cmdGroupDel) },
    .{ .name = "group-fx",    .desc = "<n>  open group n's FX chain", .run = wrap(commands_tracks.cmdGroupFx) },
    .{ .name = "track-group", .desc = "<track> <group|none>  assign (or clear) which group a track submixes through", .run = wrap(commands_tracks.cmdTrackGroup) },
    .{ .name = "track-send",  .desc = "<track> <slot> none|master|<group> [<dB>]  set (or clear) a track's parallel aux send", .run = wrap(commands_tracks.cmdTrackSend) },
    .{ .name = "ctrl",        .desc = "[<n> [shape] [beats] [depth] [phase]]  list, create or retune a modulation controller", .run = wrap(commands_tracks.cmdController) },
    .{ .name = "ctrl-bind",   .desc = "<n>  wire controller n to the param under the open editor's cursor", .run = wrap(commands_tracks.cmdControllerBind) },
    .{ .name = "ctrl-clear",  .desc = "<n>  free controller n and every knob it drives", .run = wrap(commands_tracks.cmdControllerClear) },
    .{ .name = "cc",          .desc = "[<number>]  list learned MIDI bindings, or bind one to the param under the cursor", .run = wrap(commands_tracks.cmdCc) },
    .{ .name = "cc-learn",    .desc = "arm MIDI learn on the param under the cursor - the next knob you move binds to it", .run = wrap(commands_tracks.cmdCcLearn) },
    .{ .name = "cc-clear",    .desc = "[<number>]  drop one MIDI binding, or all of them", .run = wrap(commands_tracks.cmdCcClear) },
    .{ .name = "write",       .desc = "[file]  save project (default: project.wsj)", .run = wrap(commands_mixer.cmdSave) },
    .{ .name = "w",           .desc = "[file]  save project (alias for :write)",     .run = wrap(commands_mixer.cmdSave) },
    .{ .name = "write-quit",  .desc = "[file]  save project and quit",               .run = wrap(commands_mixer.cmdWriteQuit) },
    .{ .name = "wq",          .desc = "[file]  save project and quit (alias for :write-quit)", .run = wrap(commands_mixer.cmdWriteQuit) },
    .{ .name = "x",           .desc = "[file]  save project and quit (alias for :write-quit)", .run = wrap(commands_mixer.cmdWriteQuit) },
    .{ .name = "wq!",         .desc = "[file]  save project and quit (alias for :write-quit)", .run = wrap(commands_mixer.cmdWriteQuit) },
    .{ .name = "bounce",       .desc = "[file] [16|24]  render session (wav, or .flac/.ogg by extension)", .run = wrap(commands_mixer.cmdBounce) },
    .{ .name = "bounce-stems", .desc = "[dir] [16|24]  render each non-empty track soloed to <dir>/<N>-<track>.wav (default: stems/)", .run = wrap(commands_mixer.cmdBounceStems) },
    .{ .name = "reference",    .desc = "[track|off]  designate and A/B a loudness-matched reference track", .run = wrap(commands_mixer.cmdReference) },
    .{ .name = "clear",       .desc = "erase all notes in the piano-roll pattern, or every pad in a drum machine", .run = wrap(cmdClear), .scope = .{ .drum = true, .sampler = true, .synth = true, .slicer = true, .soundfont = true, .acoustic = true } },
    .{ .name = "%d",          .desc = "erase all notes/hits in the pattern (alias for :clear)",  .run = wrap(cmdClear), .scope = .{ .drum = true, .sampler = true, .synth = true, .slicer = true, .soundfont = true, .acoustic = true } },
    .{ .name = "humanize",    .desc = "[amount]  jitter the pattern's note timing/velocity 0-100% (default 15)", .run = wrap(cmdHumanize), .scope = .{ .drum = true, .sampler = true, .synth = true, .slicer = true, .soundfont = true, .acoustic = true } },
    .{ .name = "quantize",    .desc = "[strength]  snap the pattern's notes to the current grid 0-100% (default 100, hard snap)", .run = wrap(cmdQuantize), .scope = .{ .sampler = true, .synth = true, .slicer = true, .soundfont = true, .acoustic = true } },
    .{ .name = "swing",       .desc = "[percent]  piano-roll pattern swing 50-75% (default 50, straight) - matches the drum machine's", .run = wrap(commands_pattern.cmdSwing), .scope = .{ .sampler = true, .synth = true, .slicer = true, .soundfont = true, .acoustic = true } },
    .{ .name = "reverse",     .desc = "retrograde: mirror the pattern in time (visual-mode r reverses just the selection)", .run = wrap(commands_pattern.cmdReverse), .scope = .{ .drum = true, .sampler = true, .synth = true, .slicer = true, .soundfont = true, .acoustic = true } },
    .{ .name = "invert",      .desc = "[pitch]  mirror the pattern around a pitch axis (default: its first note) - :reverse's vertical twin", .run = wrap(commands_pattern.cmdInvert), .scope = .{ .sampler = true, .synth = true, .slicer = true, .soundfont = true, .acoustic = true } },
    .{ .name = "double",      .desc = "copy the pattern after itself and double the loop length - vary the back half from there", .run = wrap(commands_pattern.cmdDouble), .scope = .{ .sampler = true, .synth = true, .slicer = true, .soundfont = true, .acoustic = true } },
    .{ .name = "fit",         .desc = "shrink or grow the loop to the bar the last note ends in", .run = wrap(commands_pattern.cmdFit), .scope = .{ .sampler = true, .synth = true, .slicer = true, .soundfont = true, .acoustic = true } },
    .{ .name = "dedupe",      .desc = "drop notes stacked on an identical pitch and start, keeping the longest of each pile", .run = wrap(commands_pattern.cmdDedupe), .scope = .{ .sampler = true, .synth = true, .slicer = true, .soundfont = true, .acoustic = true } },
    .{ .name = "normalize",   .desc = "lift every velocity until the loudest note peaks, keeping the dynamics between them (drum view: the whole kit)", .run = wrap(commands_pattern.cmdNormalize), .scope = .{ .drum = true, .sampler = true, .synth = true, .slicer = true, .soundfont = true, .acoustic = true } },
    .{ .name = "vel-ramp",    .desc = "<from> <to>  velocity ramp 0-100% across the pattern's notes (drum view: the cursor pad's hits)", .run = wrap(commands_pattern.cmdVelRamp), .scope = .{ .drum = true, .sampler = true, .synth = true, .slicer = true, .soundfont = true, .acoustic = true } },
    .{ .name = "legato",      .desc = "extend every note to the next onset - gapless phrasing, no more staccato gaps", .run = wrap(commands_pattern.cmdLegato), .scope = .{ .sampler = true, .synth = true, .slicer = true, .soundfont = true, .acoustic = true } },
    .{ .name = "glue",        .desc = "weld touching or overlapping same-pitch notes into one long note", .run = wrap(commands_pattern.cmdGlue), .scope = .{ .sampler = true, .synth = true, .slicer = true, .soundfont = true, .acoustic = true } },
    .{ .name = "chop-notes",  .desc = "split every note into pieces one grid step long (the inverse of :glue)", .run = wrap(commands_pattern.cmdChopNotes), .scope = .{ .sampler = true, .synth = true, .slicer = true, .soundfont = true, .acoustic = true } },
    .{ .name = "transpose",   .desc = "<semitones>  shift every note in the pattern (visual-mode j/k/J/K transposes just the selection)", .run = wrap(commands_pattern.cmdTranspose), .scope = .{ .sampler = true, .synth = true, .slicer = true, .soundfont = true, .acoustic = true } },
    .{ .name = "strum",       .desc = "<ms>  stagger each chord's notes by ms per rank - positive low-to-high, negative high-to-low", .run = wrap(commands_pattern.cmdStrum), .scope = .{ .sampler = true, .synth = true, .slicer = true, .soundfont = true, .acoustic = true } },
    .{ .name = "flam",        .desc = "<ms> [repeats]  echo every note ms apart at fading velocity (negative ms = grace notes before)", .run = wrap(commands_pattern.cmdFlam), .scope = .{ .sampler = true, .synth = true, .slicer = true, .soundfont = true, .acoustic = true } },
    .{ .name = "arpeggiate",  .desc = "[down]  spread every chord into an arpeggio, one grid step per note", .run = wrap(commands_pattern.cmdArpeggiate), .scope = .{ .sampler = true, .synth = true, .slicer = true, .soundfont = true, .acoustic = true } },
    .{ .name = "limit",       .desc = "<lo> <hi>  fold every note into a MIDI pitch range by octaves (e.g. :limit 48 72)", .run = wrap(commands_pattern.cmdLimit), .scope = .{ .sampler = true, .synth = true, .slicer = true, .soundfont = true, .acoustic = true } },
    .{ .name = "discard-lengths", .desc = "reset every note to the roll's default length - throw away hand-drawn lengths", .run = wrap(commands_pattern.cmdDiscardLengths), .scope = .{ .sampler = true, .synth = true, .slicer = true, .soundfont = true, .acoustic = true } },
    .{ .name = "import-midi", .desc = "<file>  replace the pattern with a Standard MIDI File's notes",     .run = wrap(commands_pattern.cmdImportMidi), .scope = .{ .sampler = true, .synth = true, .slicer = true, .soundfont = true, .acoustic = true } },
    .{ .name = "export-midi", .desc = "<file>  write the pattern as a Standard MIDI File",                 .run = wrap(commands_pattern.cmdExportMidi), .scope = .{ .sampler = true, .synth = true, .slicer = true, .soundfont = true, .acoustic = true } },
    .{ .name = "metronome",   .desc = "[on|off]  toggle the click track",                   .run = wrap(cmdMetronome) },
    .{ .name = "monitor",     .desc = "[off|auto|on]  input monitoring mode",                .run = wrap(cmdMonitor) },
    .{ .name = "punch",       .desc = "[on|off]  record only inside the enabled A/B bounds", .run = wrap(cmdPunch) },
    .{ .name = "scale",       .desc = "[<root> [<type>]|off]  piano-roll scale highlight + chord-stamp key", .run = wrap(cmdScale) },
    .{ .name = "tuning",      .desc = "[<name> [<root>]]  temperament synths play in: equal, just_major, pythagorean, meantone_quarter, werckmeister3, kirnberger3", .run = wrap(cmdTuning) },
    .{ .name = "snap-scale",  .desc = "[<root> [<type>]]  pull every off-scale note onto the nearest tone of the active :scale", .run = wrap(commands_pattern.cmdSnapScale), .scope = .{ .sampler = true, .synth = true, .slicer = true, .soundfont = true, .acoustic = true } },
    .{ .name = "ghost",       .desc = "[on|off]  dim every other melodic track's notes into the piano-roll background", .run = wrap(cmdGhost) },
    .{ .name = "audition",    .desc = "[on|off]  preview the pitch under the piano-roll cursor on every j/k move", .run = wrap(cmdAudition) },
    .{ .name = "synth-preset", .desc = "[name]  apply a factory or saved synth patch to the cursor track (no args: list names)", .run = wrap(commands_load.cmdSynthPreset), .scope = .{ .synth = true } },
    .{ .name = "synth-preset-save", .desc = "<name>  save the cursor track's current synth params as a reusable preset", .run = wrap(commands_load.cmdSynthPresetSave), .scope = .{ .synth = true } },
    .{ .name = "drum-kit",    .desc = "[name]  apply a factory or saved kit to the cursor drum machine (no args: list names)", .run = wrap(commands_load.cmdDrumKit), .scope = .{ .drum = true } },
    .{ .name = "drum-kit-save", .desc = "<name>  save the cursor drum machine's pad tuning (name/gain/pan/pitch/ADSR/choke, no audio) as a reusable kit", .run = wrap(commands_load.cmdDrumKitSave), .scope = .{ .drum = true } },
    .{ .name = "split-drums", .desc = "replace the drum machine with one sampler + MIDI track per loaded pad", .run = wrap(commands_tracks.cmdSplitDrums), .scope = .{ .drum = true } },
    .{ .name = "euclid",      .desc = "<pulses|preset> [rotation]  Euclidean rhythm across the cursor pad's lane (:euclid tresillo)", .run = wrap(cmdEuclid), .scope = .{ .drum = true } },
    .{ .name = "rotate",      .desc = "<steps>  rotate the cursor pad's lane in time, wrapping (negative = earlier)", .run = wrap(cmdRotate), .scope = .{ .drum = true } },
    .{ .name = "undo",         .desc = "undo the last edit (alias for the u key)",   .run = wrap(cmdUndo) },
    .{ .name = "redo",         .desc = "redo the last undone edit (alias for the U key)", .run = wrap(cmdRedo) },
    .{ .name = "plugin-scan",  .desc = "rescan configured CLAP and VST3 plugin paths", .run = wrap(cmdPluginScan) },
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
/// file doesn't (`App.dirty`). :q! / :qa! force.
fn cmdQuit(app: *App, _: []const u8) void {
    _ = app.requestQuit();
}
// zig fmt: off

fn cmdQuitForce(app: *App, _: []const u8) void { app.should_quit = true; }

fn cmdEdit(app: *App, args: []const u8) void { editOrRevert(app, args, false); }
fn cmdEditForce(app: *App, args: []const u8) void { editOrRevert(app, args, true); }
fn cmdRecent(app: *App, _: []const u8) void { app.openRecentProjects(); }
fn cmdPluginScan(app: *App, _: []const u8) void { app.rescanExternalPlugins(); }
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
        if (err == error.ClapPluginIsNotEffect)
            app.setStatus("CLAP plugin has no main audio input", .{})
        else
            app.setStatus("CLAP effect: {s}", .{@errorName(err)});
        return;
    };
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

pub fn cmdClapGui(app: *App, _: []const u8) void {
    const plugin = blk: {
        if (app.view == .track_spectrum or app.view == .master_spectrum or app.view == .group_spectrum) {
            const fx = spectrum_ed.fxPtr(app, spectrum_ed.currentTarget(app)) orelse break :blk null;
            const unit = spectrum_ed.focusedUnit(app, fx) orelse break :blk null;
            break :blk switch (unit.payload) {
                .clap => |plugin| plugin,
                else => null,
            };
        }
        const track = app.cursorTrack() orelse break :blk null;
        break :blk switch (app.session.racks.items[track].instrument) {
            .clap => |plugin| plugin,
            else => null,
        };
    } orelse {
        app.setStatus("current instrument or focused effect is not CLAP", .{});
        return;
    };
    const visible = plugin.toggleGui() catch |err| {
        app.setStatus("CLAP GUI: {s}", .{@errorName(err)});
        return;
    };
    app.setStatus("CLAP GUI {s}: {s}", .{ if (visible) "opened" else "hidden", plugin.name() });
}

pub fn cmdVst3Gui(app: *App, _: []const u8) void {
    const plugin = blk: {
        if (app.view == .track_spectrum or app.view == .master_spectrum or app.view == .group_spectrum) {
            const fx = spectrum_ed.fxPtr(app, spectrum_ed.currentTarget(app)) orelse break :blk null;
            const unit = spectrum_ed.focusedUnit(app, fx) orelse break :blk null;
            break :blk switch (unit.payload) {
                .vst3 => |plugin| plugin,
                else => null,
            };
        }
        const track = app.cursorTrack() orelse break :blk null;
        break :blk switch (app.session.racks.items[track].instrument) {
            .vst3 => |plugin| plugin,
            else => null,
        };
    } orelse {
        app.setStatus("current instrument or focused effect is not VST3", .{});
        return;
    };
    const visible = plugin.toggleGui() catch |err| {
        app.setStatus("VST3 GUI: {s}", .{@errorName(err)});
        return;
    };
    app.setStatus("VST3 GUI {s}", .{if (visible) "opened" else "closed"});
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

/// `:clear` - erase every note in a melodic pattern, or (same
/// track-resolution rule as `:reverse`) wipe every pad in a drum machine
/// when there's no melodic pattern to clear - the fast way back to a blank
/// kit instead of clearing pads one by one.
fn cmdClear(app: *App, _: []const u8) void {
    if (commands_util.resolveMelodic(app)) |m| {
        const n = m.pp.note_count;
        history.recordMelodic(app, @intCast(m.track));
        m.pp.clearNotes();
        app.setStatus("cleared {d} notes", .{n});
        piano_ed.syncLinkedClip(app);
        return;
    }
    if (commands_util.cursorDrumTrack(app)) |drum_track| {
        const dm = commands_util.cursorDrumMachine(app).?;
        history.recordDrum(app, drum_track);
        const n = dm.clearKit();
        app.setStatus("cleared {d} hits", .{n});
        return;
    }
    app.setStatus("clear: no pattern here", .{});
}

/// `:humanize [amount]` - jitters every note in the pattern's timing (±amount%
/// of one grid step) and velocity (±amount%, relative), 0-100 (default 15).
/// A drum machine has no fractional timing to jitter (a hit's only an
/// integer step), so its fallback (same track-resolution rule as `:reverse`)
/// jitters hit velocity only - dynamics without moving anything off-grid.
fn cmdHumanize(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    const amount: f64 = if (trimmed.len == 0) 15.0 else parseFiniteFloat(f64, trimmed) catch {
        app.setStatus("humanize: expected a percent, e.g. :humanize 15", .{});
        return;
    };
    if (amount < 0.0 or amount > 100.0) {
        app.setStatus("humanize: amount must be 0-100", .{});
        return;
    }
    const seed: u64 = @truncate(@as(u96, @bitCast(app.now_ns)));
    if (commands_util.resolveMelodic(app)) |m| {
        history.recordMelodic(app, @intCast(m.track));
        const step_beats = 1.0 / @as(f64, @floatFromInt(app.pianoStepsPerBeat()));
        m.pp.humanize(amount, step_beats, seed);
        app.setStatus("humanized {d} notes ({d:.0}%)", .{ m.pp.note_count, amount });
        piano_ed.syncLinkedClip(app);
        return;
    }
    if (commands_util.cursorDrumTrack(app)) |drum_track| {
        const dm = commands_util.cursorDrumMachine(app).?;
        history.recordDrum(app, drum_track);
        dm.humanizeVelocity(amount, seed);
        app.setStatus("humanized drum velocities ({d:.0}%)", .{amount});
        return;
    }
    app.setStatus("humanize: no pattern here", .{});
}

/// `:quantize [strength]` - snap every note's start toward the current view
/// grid (`piano_division`, `T`/`z`/`Z` set it), 0-100% (default 100, hard
/// snap). The deliberate counterpart to `:humanize`'s jitter - same
/// track-resolution rule.
fn cmdQuantize(app: *App, args: []const u8) void {
    const m = commands_util.resolveMelodic(app) orelse {
        app.setStatus("quantize: no piano-roll pattern", .{});
        return;
    };
    const trimmed = std.mem.trim(u8, args, " ");
    const strength: f64 = if (trimmed.len == 0) 100.0 else parseFiniteFloat(f64, trimmed) catch {
        app.setStatus("quantize: expected a percent, e.g. :quantize 100", .{});
        return;
    };
    if (strength < 0.0 or strength > 100.0) {
        app.setStatus("quantize: strength must be 0-100", .{});
        return;
    }
    history.recordMelodic(app, @intCast(m.track));
    const step_beats = 1.0 / @as(f64, @floatFromInt(app.pianoStepsPerBeat()));
    m.pp.quantize(step_beats, strength);
    app.setStatus("quantized to {s} ({d:.0}%)", .{ app.piano_division.label(), strength });
    piano_ed.syncLinkedClip(app);
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
                app.setStatus("colorscheme: unknown name (press Tab to list built-ins)", .{});
                return;
            };
            rt.config.gui_theme = name;
        },
        .tui => {
            const name = std.meta.stringToEnum(config_mod.TuiTheme, trimmed) orelse {
                app.setStatus("colorscheme: unknown name (press Tab to list built-ins)", .{});
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
        .synth_editor => .synth_editor,
        .piano_roll => .piano_roll,
        .arrangement => .arrangement,
        .automation, .automation_param_picker => .automation,
        .track_spectrum, .master_spectrum, .group_spectrum, .fx_picker => .spectrum,
        // zig fmt: off
        .file_browser => .file_browser,
        .preset_picker => switch (app.preset_picker_kind) { .synth => .synth_editor, .drum => .drum_grid, .soundfont, .acoustic => .soundfont_editor },
        // zig fmt: on
        .help, .instrument_picker => null,
    };
    app.prev_view = app.view;
    app.help_scroll = help_view.scrollForSection(section, app.allCmds(), app.userKeymapsSlice());
    app.help_search_hit = null;
    app.view = .help;
}

fn cmdMetronome(app: *App, args: []const u8) void {
    const on = onOffArg(app, "metronome", args, app.session.metronome_enabled) orelse return;
    app.session.setMetronome(on);
    app.setStatus("metronome {s}", .{if (on) "on" else "off"});
}

fn cmdMonitor(app: *App, args: []const u8) void {
    const value = std.mem.trim(u8, args, " ");
    if (value.len == 0) {
        app.setStatus("input monitor {s}", .{@tagName(app.input_monitor)});
        return;
    }
    const mode: app_mod.InputMonitor = if (std.mem.eql(u8, value, "off"))
        .off
    else if (std.mem.eql(u8, value, "auto"))
        .auto
    else if (std.mem.eql(u8, value, "on"))
        .on
    else {
        app.setStatus("monitor: expected off, auto, or on", .{});
        return;
    };
    _ = app.setInputMonitor(mode);
}

fn cmdPunch(app: *App, args: []const u8) void {
    const on = onOffArg(app, "punch", args, app.punch_enabled) orelse return;
    _ = app.setPunch(on);
}

/// Shared `[on|off]` argument form: no argument toggles `current`.
fn onOffArg(app: *App, command: []const u8, args: []const u8, current: bool) ?bool {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) return !current;
    if (std.mem.eql(u8, trimmed, "on")) return true;
    if (std.mem.eql(u8, trimmed, "off")) return false;
    app.setStatus("{s}: expected on or off (omit value to toggle)", .{command});
    return null;
}

/// `:ghost [on|off]` - toggles dimmed "ghost notes" from every other melodic
/// track into the piano roll's background (see `App.piano_ghost`).
fn cmdGhost(app: *App, args: []const u8) void {
    const on = onOffArg(app, "ghost", args, app.piano_ghost) orelse return;
    app.piano_ghost = on;
    app.setStatus("ghost notes {s}", .{if (on) "on" else "off"});
}

/// `:audition [on|off]` - toggles previewing the pitch under the piano-roll
/// cursor on every j/k move (see `App.piano_audition`).
fn cmdAudition(app: *App, args: []const u8) void {
    const on = onOffArg(app, "audition", args, app.piano_audition) orelse return;
    app.piano_audition = on;
    app.setStatus("cursor audition {s}", .{if (on) "on" else "off"});
}

/// `:scale [<root> [<type>]|off]` - sets or clears the piano roll's active
/// project scale. With no args, reports the current setting.
/// `<type>` alone (root omitted) keeps the existing root, defaulting to C.
pub fn cmdScale(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        if (app.session.project.scale) |s|
            app.setStatus("scale: {s} {s}", .{ theory.pitchClassName(s.root), s.kind.label() })
        else
            app.setStatus("scale: off", .{});
        return;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "off")) {
        app.setScale(null);
        return;
    }
    var it = std.mem.splitScalar(u8, trimmed, ' ');
    const first = it.next().?;
    const rest = std.mem.trim(u8, it.rest(), " ");
    // A bare type name (e.g. `:scale dorian`) keeps the existing root.
    var root: u4 = if (app.session.project.scale) |s| s.root else 0;
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
    else if (app.session.project.scale) |s|
        s.kind
    else
        .major;
    app.setScale(.{ .root = root, .kind = kind });
}

/// `:tuning [<name> [<root>]]` - the temperament pitched instruments play
/// in. Orthogonal to `:scale`, which only decides which of the twelve keys
/// the piece uses; this decides what frequency those keys sound at.
pub fn cmdTuning(app: *App, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " ");
    if (trimmed.len == 0) {
        const t = app.session.project.tuning;
        if (t.isEqual())
            app.setStatus("tuning: equal (12-TET)", .{})
        else
            app.setStatus("tuning: custom, root {s}", .{theory.pitchClassName(t.root)});
        return;
    }
    var it = std.mem.splitScalar(u8, trimmed, ' ');
    const name = it.next().?;
    const rest = std.mem.trim(u8, it.rest(), " ");
    const preset = tuning_mod.Preset.parse(name) orelse {
        app.setStatus("tuning: unknown '{s}' (try equal/just_major/pythagorean/…)", .{name});
        return;
    };
    // A bare name keeps the root already in use, so walking the temperaments
    // to audition them doesn't reset the key each time.
    const root: u4 = if (rest.len > 0)
        theory.parsePitchClass(rest) orelse {
            app.setStatus("tuning: unknown root '{s}'", .{rest});
            return;
        }
    else
        app.session.project.tuning.root;
    app.session.setTuning(preset.tuning(root));
    app.dirty = true;
    app.setStatus("tuning: {s}, root {s}", .{ preset.label(), theory.pitchClassName(root) });
}

pub const EuclidPreset = struct {
    name: []const u8,
    pulses: u16,
    rotation: i32,
};

/// Named pulse/rotation pairs. The current pattern remains the step count,
/// matching numeric `:euclid`; names describe their familiar form at common
/// 8- or 16-step lengths without resizing every pad in the drum machine.
pub const euclid_presets = [_]EuclidPreset{
    .{ .name = "tresillo", .pulses = 3, .rotation = 0 },
    .{ .name = "cinquillo", .pulses = 5, .rotation = 0 },
    .{ .name = "bossa", .pulses = 5, .rotation = 2 },
    .{ .name = "clave", .pulses = 5, .rotation = 3 },
    .{ .name = "rumba", .pulses = 5, .rotation = 5 },
    .{ .name = "four-floor", .pulses = 4, .rotation = 0 },
};

fn findEuclidPreset(name: []const u8) ?EuclidPreset {
    for (euclid_presets) |preset| {
        if (std.ascii.eqlIgnoreCase(name, preset.name)) return preset;
    }
    return null;
}

/// `:euclid <pulses|preset> [rotation]` - replace the cursor pad's lane with a
/// Euclidean rhythm: `pulses` hits spread as evenly as possible across the
/// whole pattern, optionally rotated so the first hit lands `rotation` steps
/// in. E(3,8) is the tresillo, E(5,16) a classic hat groove.
fn cmdEuclid(app: *App, args: []const u8) void {
    const track = commands_util.cursorDrumTrack(app) orelse {
        app.setStatus("euclid: select a drum-machine track first", .{});
        return;
    };
    const dm = commands_util.cursorDrumMachine(app).?;
    var it = std.mem.tokenizeScalar(u8, args, ' ');
    const rhythm = it.next() orelse {
        app.setStatus("usage: euclid <pulses|preset> [rotation], e.g. :euclid tresillo", .{});
        return;
    };
    const preset = findEuclidPreset(rhythm);
    const pulses = if (preset) |p| p.pulses else std.fmt.parseInt(u16, rhythm, 10) catch {
        app.setStatus("euclid: unknown preset or bad pulse count '{s}'", .{rhythm});
        return;
    };
    const rotation: i32 = if (it.next()) |rot_str| std.fmt.parseInt(i32, rot_str, 10) catch {
        app.setStatus("euclid: bad rotation '{s}'", .{rot_str});
        return;
    } else if (preset) |p| p.rotation else 0;
    if (pulses > dm.step_count) {
        app.setStatus("euclid: at most {d} pulses fit this pattern", .{dm.step_count});
        return;
    }
    const pad: u8 = @intCast(app.drum_cursor[0]);
    history.recordDrum(app, track);
    dm.euclidPad(pad, pulses, rotation);
    if (preset) |p|
        app.setStatus("euclid {s}: E({d},{d}) rot {d} on pad {d} ({s})", .{ p.name, pulses, dm.step_count, rotation, pad + 1, dm.padName(pad) })
    else
        app.setStatus("euclid E({d},{d}) rot {d} on pad {d} ({s})", .{ pulses, dm.step_count, rotation, pad + 1, dm.padName(pad) });
}

test "Euclidean rhythm presets resolve case-insensitively" {
    const tresillo = findEuclidPreset("Tresillo").?;
    try std.testing.expectEqual(@as(u16, 3), tresillo.pulses);
    try std.testing.expectEqual(@as(i32, 0), tresillo.rotation);
    try std.testing.expect(findEuclidPreset("unknown") == null);
}

/// `:rotate <steps>` - rotate the cursor pad's lane in time (positive =
/// later, negative = earlier), wrapping at the pattern boundary. Hits keep
/// their velocity; only their grid position moves.
fn cmdRotate(app: *App, args: []const u8) void {
    const track = commands_util.cursorDrumTrack(app) orelse {
        app.setStatus("rotate: select a drum-machine track first", .{});
        return;
    };
    const dm = commands_util.cursorDrumMachine(app).?;
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
    history.recordDrum(app, track);
    dm.rotatePad(pad, delta);
    app.setStatus("rotated pad {d} ({s}) {s}{d} steps", .{ pad + 1, dm.padName(pad), if (delta >= 0) "+" else "", delta });
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

test ":write reports the expanded path, not the literal ~, on failure" {
    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    const home_c = std.c.getenv("HOME") orelse return error.SkipZigTest;
    const home = std.mem.sliceTo(home_c, 0);

    // A directory that doesn't exist under $HOME - save fails, but the
    // status must show where it actually tried to write.
    var cmd_buf: [80]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, ":write ~/__wstudio_missing__/p.wsj", .{});
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
    try @import("store/json.zig").testRedirectHome(&tmp);

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

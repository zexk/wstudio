//! TUI frontend entry point: terminal lifecycle, the input/render main
//! loop, and the per-frame draw pipeline (header, view body, transport,
//! prompt, status). The frontend-agnostic application core lives in
//! ui/app.zig; per-view renderers in views/<name>.zig via the tui.zig
//! facade.

const std = @import("std");
const builtin = @import("builtin");
const ws = @import("wstudio");
const types = ws.types;
const backend_mod = ws.backend;
const modal_mod = ws.input;
const Transport = ws.Transport;
const Engine = ws.engine.Engine;
const terminal_mod = if (builtin.os.tag == .windows) @import("terminal_windows.zig") else @import("terminal.zig");
const config_mod = @import("../config.zig");
const app_mod = @import("../ui/app.zig");
const App = app_mod.App;
const commands = @import("../ui/commands.zig");
const cmd_mod = @import("../ui/cmd.zig");
const icons = @import("../ui/icons.zig");
const spectrum_ed = @import("../ui/editors/spectrum.zig");
const drum_ed = @import("../ui/editors/drum.zig");
const slicer_ed = @import("../ui/editors/slicer.zig");
const piano_ed = @import("../ui/editors/piano.zig");
const tui = @import("tui.zig");
const style = @import("style.zig");
const tui_theme = @import("theme.zig");

/// Smallest terminal the layouts are actually built for: the FX chain's
/// slot strip is sized "nine boxes + ▶OUT = 78 cols" for 80-col
/// terminals, and the row budgets were audited down to 14 rows. Below
/// this, content lines wrap and shove the frame apart - show a notice
/// instead (btop-style) rather than fighting per-view overflow.
pub const min_cols: usize = 80;
pub const min_rows: usize = 14;

pub fn draw(self: *App, w: *std.Io.Writer, size: terminal_mod.Size) !void {
    self.last_cols = size.cols;
    if (size.cols < min_cols or size.rows < min_rows) {
        try drawTooSmall(w, size);
        return;
    }
    const snap = self.session.engine.uiSnapshot();
    const rows: usize = @max(size.rows, 10);

    // Form-primitive width knobs: back to the compact defaults each
    // frame, so a wide view's opt-in never leaks into the next view.
    style.form_bar_w = style.form_bar_w_default;
    style.form_section_w = style.form_section_w_default;

    // Command-mode's Tab-completion popup (see cmd.writeSuggestionBox)
    // sits directly above the `:` prompt, drawn after the transport
    // line's closing hr below. Carve its rows out of the content area's
    // budget up front so the frame never grows taller than the terminal.
    const max_suggestion_rows = 10;
    const suggestion_rows: usize = if (self.modal.mode == .command and self.suggest_popup_open)
        cmd_mod.suggestionRows(self.allCmds(), self.suggestionFilterText(), commands.activeScope(self), max_suggestion_rows)
    else
        0;
    const content_rows = rows -| suggestion_rows;

    try w.writeAll("\x1b[H");
    // The .wsj format has no project-name field, so a loaded file would
    // otherwise sit under the default "untitled" - show its basename.
    const header_title: []const u8 = if (self.projectPath()) |p| std.fs.path.basename(p) else self.session.project.name;
    // Rendered into a scratch buffer and replayed via style.writeChromeRow
    // (clamp + clean line-end, no separate hr() rule row underneath) -
    // reclaims a row versus the old plain-line-plus-rule layout.
    var header_scratch: [512]u8 = undefined;
    var header_w = std.Io.Writer.fixed(&header_scratch);
    try tui.drawHeader(&header_w, header_title, &self.session.engine.transport, self.audio_label, self.master_gain_db, self.dirty);
    try style.writeChromeRow(w, header_w.buffered(), size.cols);

    // zig fmt: off
    switch (self.view) {
        .tracks          => try tui.drawTracks(self, w, content_rows, size.cols, snap),
        .drum_grid       => try tui.drawDrumGrid(self, w, content_rows, size.cols, snap),
        .synth_editor    => try tui.drawSynthEditor(self, w, content_rows, size.cols, snap),
        .sampler_editor  => try tui.drawSamplerEditor(self, w, content_rows, size.cols, snap),
        .piano_roll      => try tui.drawPianoRoll(self, w, content_rows, size.cols, snap),
        .help            => try tui.drawHelp(w, content_rows, size.cols, self.allCmds(), self.userKeymapsSlice(), &self.help_scroll, self.help_search_hit),
        .track_spectrum, .master_spectrum, .group_spectrum =>
            try tui.drawFxView(self, w, content_rows, size.cols, snap, spectrum_ed.currentTarget(self)),
        .instrument_picker => try tui.drawInstrumentPicker(self, w, content_rows),
        .fx_picker       => try tui.drawFxPicker(self, w, content_rows),
        .synth_fx_picker => try tui.drawSynthFxPicker(self, w, content_rows),
        .arrangement     => try tui.drawArrangement(self, w, content_rows, size.cols, snap),
        .file_browser    => try tui.drawFileBrowser(self, w, content_rows),
        .automation      => try tui.drawAutomation(self, w, content_rows, size.cols, snap),
        .automation_param_picker => try tui.drawAutomationParamPicker(self, w, content_rows),
        .slicer_grid     => try tui.drawSlicerGrid(self, w, content_rows, size.cols, snap),
        .preset_picker   => try tui.drawPresetPicker(self, w, content_rows),
    }
    // zig fmt: on

    var transport: Transport = .{
        .sample_rate = self.session.project.sample_rate,
        .tempo_bpm = self.session.project.tempo_bpm,
        .position_frames = snap.position_frames,
    };
    // Off the arrangement timeline, the transport plays a raw straight
    // line while the audio itself loops locally (PatternPlayer/
    // DrumMachine wrap at their own length) - mirror that in the
    // bar:beat readout so it cycles instead of climbing forever.
    if (!self.session.song_mode) {
        const len_beats = self.contentBeats();
        if (len_beats > 0) {
            const fpb = transport.framesPerBeat();
            const loop_frames: u64 = @intFromFloat(len_beats * fpb);
            if (loop_frames > 0) transport.position_frames %= loop_frames;
        }
    }
    const pos = transport.positionBarBeat();
    const secs = transport.positionSeconds();
    // Left = transport state (play/stop, metronome, bar.beat, clock);
    // right = the L/R meters, pinned to the row's right edge instead of
    // trailing wherever the left content happens to end (writeSplitRow).
    var transport_scratch: [512]u8 = undefined;
    var tw = std.Io.Writer.fixed(&transport_scratch);
    if (snap.pre_rolling) {
        // No dedicated glyph for this - it's a brief, rare state, so
        // plain text beats adding another icon just for it.
        try tw.writeAll("\x1b[33m\x1b[1m count-in\x1b[0m");
    } else if (snap.playing) {
        if (icons.font_installed) {
            try tw.writeAll("\x1b[32m\x1b[1m " ++ icons.play ++ "\x1b[0m");
        } else {
            // U+25BA/U+25A0 are in CP437, so even bitmap terminal fonts
            // (PxPlus IBM VGA etc.) have them - no icon font needed.
            try tw.writeAll("\x1b[32m\x1b[1m \u{25BA}\x1b[0m");
        }
    } else {
        if (icons.font_installed) {
            try tw.writeAll("\x1b[2m " ++ icons.stop ++ "\x1b[0m");
        } else {
            try tw.writeAll("\x1b[2m \u{25A0}\x1b[0m");
        }
    }
    if (self.session.metronome_enabled) {
        try tw.writeAll(" \x1b[33m" ++ icons.tempo ++ " click\x1b[0m");
    }
    try tw.print(" {d:0>3}.{d}  {d:0>2}:{d:0>4.1}", .{
        pos.bar + 1,
        pos.beat + 1,
        @as(u64, @intFromFloat(secs / 60.0)),
        @mod(secs, 60.0),
    });
    var meter_scratch: [128]u8 = undefined;
    var mw = std.Io.Writer.fixed(&meter_scratch);
    try mw.writeAll("\x1b[2mL\x1b[0m");
    try tui.meter(&mw, snap.peak[0]);
    try mw.writeAll("\x1b[2m R\x1b[0m");
    try tui.meter(&mw, snap.peak[1]);
    try style.writeSplitRow(w, tw.buffered(), mw.buffered(), size.cols);
    try style.endLine(w);
    // The `:`/`/` prompt's own row - blank outside command/search mode.
    // Moved off the status row below so that row can keep showing the
    // mode badge/view info while a command is being typed instead of
    // being replaced by the prompt text.
    var prompt_scratch: [1024]u8 = undefined;
    var prompt_w = std.Io.Writer.fixed(&prompt_scratch);
    switch (self.modal.mode) {
        .command => try cmd_mod.writePrompt(&prompt_w, self.allCmds(), self.modal.cmd_buf[0..self.modal.cmd_len], self.modal.cmd_cursor, 60),
        .search => try cmd_mod.writeSearchPrompt(&prompt_w, self.modal.cmd_buf[0..self.modal.cmd_len], self.modal.cmd_cursor),
        else => {},
    }
    try style.writeClamped(w, prompt_w.buffered(), size.cols -| 1);
    try style.endLine(w);

    if (suggestion_rows > 0) {
        try cmd_mod.writeSuggestionBox(
            w,
            self.allCmds(),
            self.suggestionFilterText(),
            commands.activeScope(self),
            self.suggestionSelected(commands.activeScope(self)),
            max_suggestion_rows,
        );
    }

    // zig fmt: off
    // Status lines are assembled from several independent print calls
    // with no shared width budget, so a verbose message (e.g. the
    // visual-mode hint) can overflow past the terminal's right edge and
    // wrap onto a new row, scrolling the header off the top. Render into
    // a scratch buffer first and clamp to the terminal width before it
    // ever reaches the real writer.
    var status_scratch: [1024]u8 = undefined;
    var status_w = std.Io.Writer.fixed(&status_scratch);
    // The current-view name (and a couple of short state flags - zoom,
    // song/pattern) rides a second buffer and gets pinned to the row's
    // right edge via writeSplitRow, lualine's "current view is an
    // identity tag on the right, not more left-to-right reading order"
    // convention - mirrors the transport row's L/R meters above.
    var status_right_scratch: [128]u8 = undefined;
    var status_right_w = std.Io.Writer.fixed(&status_right_scratch);
    switch (self.view) {
        .tracks          => try tui.drawTracksStatus(self, &status_w, &status_right_w),
        .drum_grid       => try tui.drawDrumStatus(self, &status_w, &status_right_w),
        .synth_editor    => try tui.drawSynthStatus(self, &status_w, &status_right_w),
        .sampler_editor  => try tui.drawSamplerStatus(self, &status_w, &status_right_w),
        .piano_roll      => try tui.drawPianoRollStatus(self, &status_w, &status_right_w),
        .help            => try tui.drawHelpStatus(self, &status_w, &status_right_w),
        .track_spectrum, .master_spectrum, .group_spectrum =>
            try tui.drawFxStatus(self, &status_w, &status_right_w, spectrum_ed.currentTarget(self)),
        .instrument_picker => try tui.drawPickerStatus(self, &status_w, &status_right_w, "INSTRUMENT", "insert", false),
        .fx_picker       => try tui.drawPickerStatus(self, &status_w, &status_right_w, "EFFECT", "insert", true),
        .synth_fx_picker => try tui.drawPickerStatus(self, &status_w, &status_right_w, "SYNTH FX", "insert", true),
        .arrangement     => try tui.drawArrangementStatus(self, &status_w, &status_right_w),
        .file_browser    => try tui.drawFileBrowserStatus(self, &status_w, &status_right_w),
        .automation      => try tui.drawAutomationStatus(self, &status_w, &status_right_w),
        .automation_param_picker => try tui.drawPickerStatus(self, &status_w, &status_right_w, "PARAM", "pick", true),
        .slicer_grid     => try tui.drawSlicerStatus(self, &status_w, &status_right_w),
        .preset_picker   => try tui.drawPresetPickerStatus(self, &status_w, &status_right_w),
    }
    try style.writeSplitRow(w, status_w.buffered(), status_right_w.buffered(), size.cols -| 1);
    // Erase from cursor to end of screen so stale content from taller
    // previous frames never bleeds through.
    try w.writeAll("\x1b[K\x1b[J");
}
// zig fmt: on

/// Full-screen stand-in below min_cols x min_rows. ASCII only so the
/// byte-length centering math holds.
fn drawTooSmall(w: *std.Io.Writer, size: terminal_mod.Size) !void {
    try w.writeAll("\x1b[H");
    var buf: [64]u8 = undefined;
    const line1: []const u8 = "terminal too small";
    const line2: []const u8 = std.fmt.bufPrint(&buf, "need {d}x{d}, have {d}x{d}", .{ min_cols, min_rows, size.cols, size.rows }) catch "";
    const rows: usize = @max(size.rows, 1);
    for (0..(rows / 2) -| 1) |_| try style.endLine(w);
    try drawCenteredLine(w, line1, size.cols, style.bold);
    if (rows >= 2) try drawCenteredLine(w, line2, size.cols, style.dim);
    try w.writeAll("\x1b[K\x1b[J");
}

fn drawCenteredLine(w: *std.Io.Writer, text: []const u8, cols: u16, sgr: []const u8) !void {
    const pad = (@as(usize, cols) -| text.len) / 2;
    for (0..pad) |_| try w.writeByte(' ');
    try w.writeAll(sgr);
    try style.writeClamped(w, text, cols);
    try style.endLine(w);
}

fn renderTrampoline(ctx: *anyopaque, out: []types.Sample) void {
    const engine: *Engine = @ptrCast(@alignCast(ctx));
    // During an offline bounce the UI thread owns the engine: park here so the
    // two threads never call process() concurrently. See App.cmdBounce.
    if (engine.bounce_active.load(.acquire)) {
        @memset(out, 0.0);
        engine.bounce_parked.store(true, .release);
        return;
    }
    engine.process(out);
}

/// Set for the lifetime of `run`'s raw-mode session so `main.zig`'s panic
/// handler can find the terminal to restore before it prints the crash
/// trace - without this, a panic left the terminal in raw mode with SGR
/// mouse tracking still on: the shell reads garbled, and the panic message
/// itself is unreadable (no \r\n translation, alternate screen still up).
pub var active_terminal: ?*terminal_mod.Terminal = null;

// zig fmt: off
pub fn run(allocator: std.mem.Allocator, io: std.Io, init_path: ?[]const u8, runtime: *config_mod.Runtime) !void {
    var user_config = runtime.config;
    var term = terminal_mod.Terminal.init(io, user_config.tui_mouse) catch {
        std.debug.print(
            "wstudio: stdin is not a terminal (try `wstudio render` for the offline demo)\n",
            .{},
        );
        return;
    };
    active_terminal = &term;
    defer { term.deinit(); active_terminal = null; }
    // Registered after the deinit defer above, so it runs first at unwind
    // (LIFO) - the terminal's palette must be back to normal before
    // deinit's own leave-alt-screen sequence, not after.
    defer tui_theme.reset(&term, user_config.tui_theme);
    tui_theme.apply(&term, user_config.tui_theme);
    // zig fmt: on

    var app = try App.initWithSampleRate(allocator, io, user_config.default_sample_rate);
    defer app.deinit();
    app.applyUserConfig(user_config, init_path == null);
    icons.font_installed = icons.detectFontInstalled(io);

    // Surface a raw-mode setup failure once there's a status line to put it
    // on - see Terminal.raw_mode_ok's doc comment (Windows only; POSIX raw
    // mode failing is already fatal via tcsetattr's error return in init()).
    if (builtin.os.tag == .windows and !term.raw_mode_ok) {
        app.setStatus("warning: console raw-mode setup failed - quick edit may freeze the display", .{});
    }

    // Load project file before backends start - the backend captures the engine
    // pointer at init, so the swap must happen here.
    if (init_path) |p| {
        if (ws.persist.load(allocator, io, p)) |loaded| {
            app.session.deinit();
            app.session = loaded;
            app.setProjectPath(p);
            app.promptIfBackupNewer(p);
        } else |e| {
            std.debug.print("wstudio: cannot load '{s}': {s}\n", .{ p, @errorName(e) });
        }
    } else {
        // No project argument: a crashed pathless session's autosave lands
        // next to `:w`'s default target (see backupPath's fallback), so the
        // blank start checks the same spot the pathed start does.
        app.promptIfBackupNewer(app.defaultProjectPath());
    }

    // The app is fully initialized: route `wstudio.notify`/`wstudio.cmd`
    // into it and flush command lines queued while init.lua ran. The
    // command table must include Lua user commands before the flush, since
    // queued lines may invoke them.
    app.lua_runtime = runtime;
    app.rebuildCmdTable();
    runtime.app = &app;
    runtime.attachHost(app_mod.luaHost(&app));
    defer {
        runtime.host = null;
        runtime.app = null;
    }
    // A project opened on the command line loaded before the runtime
    // attached, so its event fires here, right after ConfigDone.
    if (app.projectPath()) |p| app.emitEvent(.{ .ProjectLoadPost = .{ .path = p } });

    var config: backend_mod.Config = .{
        .sample_rate = app.session.project.sample_rate,
        .block_frames = user_config.audio_block_frames,
    };

    // zig fmt: off
    const has_alsa = builtin.os.tag == .linux;
    const MidiIn   = if (has_alsa) ws.midi_in.MidiIn else void;
    var midi_in: MidiIn = undefined;
    // zig fmt: on

    var audio = ws.AudioHost.init(config, renderTrampoline, app.session.engine);
    try audio.start(io, user_config.audio_backend);
    defer audio.stop();

    var using_midi = false;
    if (has_alsa) {
        // zig fmt: off
        midi_in = .{ .engine = app.session.engine, .velocity_curve = .init(user_config.default_midi_velocity_curve) };
        if (midi_in.start()) {
            using_midi = true;
        } else |_| {}
        // zig fmt: on
    }
    // zig fmt: off
    defer if (has_alsa) { if (using_midi) midi_in.stop(); };
    // zig fmt: on
    app.audio_label = audio.label();

    // Sized to comfortably fit the heaviest single-view frame: the drum
    // grid at max pads (64) x max steps (64), where every cell carries its
    // own ANSI color code, runs to ~55KB on a wide+tall terminal. A fixed
    // writer that runs out mid-frame silently truncates (Writer.fixed's
    // error is swallowed below), which cuts the DEC 2026 sync bracket in
    // half and leaves the terminal stuck mid-redraw - 32KB was tight enough
    // for that to actually happen once pad/step banking stacked up.
    var frame_buf: [160 * 1024]u8 = undefined;
    var input_buf: [128]u8 = undefined;
    var keys: [64]modal_mod.Key = undefined;
    var input_decoder: terminal_mod.StreamDecoder = .{};

    while (!app.should_quit) {
        const bytes = try term.readInput(&input_buf, user_config.frame_poll_ms);
        const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
        const n = input_decoder.feed(bytes, &keys);
        for (keys[0..n]) |key| switch (key) {
            .mouse => |ev| {
                const sz = term.size();
                app.handleMouse(ev, sz.cols, sz.rows, now);
            },
            else => app.handleKey(key, now),
        };
        app.tick(now);

        // zig fmt: off
        // :e / :new asked for a session swap. Build the replacement first
        // (control-thread only, no backend involved) so a bad path or OOM
        // just reports an error and leaves the running session untouched;
        // only stop the backend once we actually have something to swap in
        // - it holds a raw *Engine pointer captured at start (or the last
        // reload), which the swap would otherwise dangle.
        if (app.pending_reload != .none) {
            const kind = app.pending_reload;
            app.pending_reload = .none;
            const new_session: ?ws.Session = switch (kind) {
                .none => unreachable,
                .blank => ws.Session.initDefault(allocator) catch |e| blk: {
                    app.setStatus("new: {s}", .{@errorName(e)});
                    break :blk null;
                },
                .load, .restore_backup => blk: {
                    const path = app.pendingReloadPath();
                    if (ws.persist.load(allocator, io, path)) |loaded| {
                        break :blk loaded;
                    } else |e| {
                        app.setStatus("e: cannot load '{s}': {s}", .{ path, @errorName(e) });
                        break :blk null;
                    }
                },
            };
            if (new_session) |loaded| {
                audio.stop();
                if (has_alsa) { if (using_midi) midi_in.stop(); }

                app.session.deinit();
                app.session = loaded;
                app.resetForNewSession();
                switch (kind) {
                    .load => app.setProjectPath(app.pendingReloadPath()),
                    // Keep the original project path - the backup's content
                    // replaces the in-memory session but `:w` should still
                    // write back to the real file, not `<path>~`.
                    .restore_backup => { app.dirty = true; app.setStatus("restored from autosave backup - :write to keep it", .{}); },
                    .blank => app.project_path_len = 0,
                    .none => unreachable,
                }
                // A blank session is a new project, not a load - no event.
                if (kind != .blank) app.emitEvent(.{ .ProjectLoadPost = .{ .path = app.pendingReloadPath() } });

                config = .{
                    .sample_rate = app.session.project.sample_rate,
                    .block_frames = user_config.audio_block_frames,
                };
                audio = ws.AudioHost.init(config, renderTrampoline, app.session.engine);
                // A restart failure here just leaves the session silent
                // rather than tearing down the whole running app.
                audio.start(io, user_config.audio_backend) catch {};
                using_midi = false;
                if (has_alsa) {
                    midi_in = .{ .engine = app.session.engine, .velocity_curve = .init(user_config.default_midi_velocity_curve) };
                    if (midi_in.start()) { using_midi = true; } else |_| {}
                }
                app.audio_label = audio.label();
                switch (kind) {
                    .load => app.setStatus("loaded: {s}", .{app.projectPath().?}),
                    .blank => app.setStatus("new project", .{}),
                    // Status already set above ("restored from autosave...").
                    .restore_backup => {},
                    .none => unreachable,
                }
            }
        }

        // `:reload-config` - re-source init.lua, then re-apply whatever it
        // changed that main() only set up once at startup. `audio_backend`/
        // `audio_block_frames` are deliberately not among these: rebuilding
        // the audio backend from inside the frame loop is the same
        // "shouldn't happen from inside a key handler" hazard `pending_reload`
        // exists for above, and a config reload is rare enough that asking
        // for a restart to pick up a backend change is a fair trade.
        if (app.pending_config_reload) {
            app.pending_config_reload = false;
            const prev = user_config;
            if (runtime.reload(io)) |_| {
                user_config = runtime.config;
                app.afterConfigReload(user_config);
                if (user_config.tui_theme != prev.tui_theme) {
                    tui_theme.reset(&term, prev.tui_theme);
                    tui_theme.apply(&term, user_config.tui_theme);
                }
                if (user_config.tui_mouse != prev.tui_mouse) term.setMouse(user_config.tui_mouse);
                if (has_alsa and using_midi) midi_in.velocity_curve.store(user_config.default_midi_velocity_curve, .monotonic);
                app.setStatus("config reloaded", .{});
            } else |e| {
                user_config = runtime.config;
                app.afterConfigReload(user_config);
                app.setStatus("reload-config: {s}", .{@errorName(e)});
            }
        }

        // `:colorscheme` - narrower than the block above: `cmdColorscheme`
        // already wrote the new `tui_theme` into `runtime.config`, so this
        // just repaints from it (the local `user_config` copy is what
        // `oscFor`'s startup/reload call sites read, so it has to track
        // this too).
        if (app.pending_colorscheme) {
            app.pending_colorscheme = false;
            const prev_theme = user_config.tui_theme;
            user_config.tui_theme = runtime.config.tui_theme;
            if (user_config.tui_theme != prev_theme) {
                tui_theme.reset(&term, prev_theme);
                tui_theme.apply(&term, user_config.tui_theme);
            }
        }

        // MIDI input follows the TUI cursor so live playing always targets the
        // currently selected track. Written from the UI thread, read (monotonic)
        // in the MIDI reader thread.
        if (has_alsa) { if (using_midi) midi_in.active_track.store(@intCast(app.cursor), .monotonic); }

        // A MIDI CC can mutate saved instrument params straight from the
        // reader thread (PolySynth.applyCC); it has no App pointer to flag
        // `dirty` itself, so pick up its signal here once per frame instead.
        if (has_alsa) { if (using_midi and midi_in.dirty.swap(false, .acquire)) app.dirty = true; }

        // Live MIDI note recording: every note-on the reader thread saw also
        // landed in `note_queue` (audition itself already went straight to
        // the engine from that thread, unaffected by this). Drain it here
        // and feed each note through the exact same insert-mode recordNote
        // path qwerty playing uses (the `.note` action handler above) -
        // gated the same way: only in insert mode, only for the view whose
        // pattern is actually being edited. A stopped transport or wrong
        // view/mode just drops the note; the live audition already
        // happened regardless. Unlike qwerty, the played velocity comes
        // through, so a take keeps its dynamics.
        if (has_alsa) { if (using_midi) {
            while (midi_in.note_queue.pop()) |rec| {
                if (app.modal.mode != .insert) continue;
                switch (app.view) {
                    .drum_grid => drum_ed.recordNote(&app, rec.pitch, rec.vel),
                    .slicer_grid => slicer_ed.recordNote(&app, rec.pitch, rec.vel),
                    .piano_roll => piano_ed.recordNote(&app, rec.pitch, @as(f32, @floatFromInt(rec.vel)) / 127.0),
                    else => {},
                }
            }
        } }
        // zig fmt: on

        var w = std.Io.Writer.fixed(&frame_buf);
        // Bracket the frame in a DEC 2026 synchronized update, inside the
        // same single write: without it tmux/compositing terminals can
        // repaint mid-frame, which reads as flicker on plain navigation.
        w.writeAll(terminal_mod.begin_sync) catch {};
        draw(&app, &w, term.size()) catch {};
        w.writeAll(terminal_mod.end_sync) catch {};
        term.write(w.buffered());
    }

    // The main loop broke on should_quit: the session is still alive.
    app.emitEvent(.QuitPre);
}

// ---------------------------------------------------------------------------
// Tests - integration tests live in app_tests.zig
// ---------------------------------------------------------------------------

test {
    _ = @import("app_tests.zig");
}

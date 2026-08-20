//! ALSA Sequencer MIDI input. Opens a virtual port, optionally subscribes a
//! configured source, and pushes note, CC, and pitch-bend commands.

const std = @import("std");
const Engine = @import("../engine.zig").Engine;
const Spsc = @import("../../core/ring_buffer.zig").Spsc;
const midi_velocity = @import("velocity.zig");
const midi = @import("../../midi.zig");
const VelocityCurve = midi_velocity.VelocityCurve;

const c = @cImport(@cInclude("alsa/asoundlib.h"));

pub const MidiIn = struct {
    seq: ?*c.snd_seq_t = null,
    port: c_int = -1,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),
    engine: *Engine,
    /// Engine track index that receives all incoming MIDI. Write from UI thread.
    active_track: std.atomic.Value(u16) = .init(0),
    /// Raw velocity byte -> gain mapping, from `wstudio.o.default_midi_velocity_curve`.
    /// Same write-from-UI/read-from-reader-thread pattern as `active_track`.
    velocity_curve: std.atomic.Value(VelocityCurve) = .init(.linear),
    /// Set (release) by the reader thread whenever an incoming CC actually
    /// mutates a saved instrument param (see dispatch's CONTROLLER branch -
    /// applyCC writes straight into e.g. PolySynth.gain/filter_cutoff/etc.,
    /// same fields `:w` persists). The UI thread swaps it (acquire) once per
    /// frame into `App.dirty`, since this thread has no App pointer to set
    /// it on directly.
    dirty: std.atomic.Value(bool) = .init(false),
    /// Every note-on (raw MIDI pitch + velocity, velocity non-zero) also
    /// lands here, independent of the direct-to-engine audition send above.
    /// The UI thread drains it once per frame and feeds each note through
    /// the same `recordNote` insert-mode-recording path qwerty playing
    /// already uses (App.zig's `.note` action handler) - this thread has no
    /// App pointer and doesn't know the current view/mode, so it always
    /// queues and lets the UI thread decide whether a given note actually
    /// lands in a pattern. A full queue drops the note (audition already went
    /// out above; only the recording side is lost) and counts it in
    /// `dropped_notes`.
    note_queue: Spsc(RecNote, 32) = .{},
    /// Note-ons lost because the UI thread had not drained `note_queue`.
    /// Read and cleared by `App.serviceMidiInput`, which warns: the note was
    /// still auditioned, so silence here would mean a take quietly missing
    /// notes the player heard.
    dropped_notes: std.atomic.Value(u32) = .init(0),

    /// One recordable note-on: the raw pitch plus the played velocity, so a
    /// recorded take keeps its dynamics instead of flattening to the default.
    pub const RecNote = struct { pitch: u7, vel: u7 };

    pub const Error = error{ SeqOpenFailed, PortCreateFailed, SourceParseFailed, SourceConnectFailed, ThreadSpawnFailed };

    pub fn start(self: *MidiIn, source_name: []const u8) Error!void {
        if (c.snd_seq_open(&self.seq, "default", c.SND_SEQ_OPEN_INPUT, 0) < 0)
            return error.SeqOpenFailed;
        errdefer {
            _ = c.snd_seq_close(self.seq);
            self.seq = null;
        }

        _ = c.snd_seq_set_client_name(self.seq, "wstudio");
        // Older kernels reject UMP client mode. Keep legacy sequencer input
        // working there; snd_seq_ump_event_input accepts both event layouts.
        if (c.snd_seq_set_client_midi_version(self.seq, c.SND_SEQ_CLIENT_UMP_MIDI_2_0) >= 0)
            _ = c.snd_seq_set_client_ump_conversion(self.seq, 1);

        const port = c.snd_seq_create_simple_port(
            self.seq,
            "MIDI In",
            c.SND_SEQ_PORT_CAP_WRITE | c.SND_SEQ_PORT_CAP_SUBS_WRITE,
            c.SND_SEQ_PORT_TYPE_APPLICATION,
        );
        if (port < 0) return error.PortCreateFailed;
        self.port = port;

        if (source_name.len > 0) {
            var source_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
            const source_z = std.fmt.bufPrintZ(&source_buf, "{s}", .{source_name}) catch return error.SourceParseFailed;
            var source: c.snd_seq_addr_t = undefined;
            if (c.snd_seq_parse_address(self.seq, &source, source_z) < 0) return error.SourceParseFailed;
            if (c.snd_seq_connect_from(self.seq, self.port, source.client, source.port) < 0) return error.SourceConnectFailed;
        }

        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch {
            self.running.store(false, .release);
            return error.ThreadSpawnFailed;
        };
    }

    pub fn stop(self: *MidiIn) void {
        self.running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        if (self.seq) |seq| {
            if (self.port >= 0) {
                _ = c.snd_seq_delete_simple_port(seq, self.port);
                self.port = -1;
            }
            _ = c.snd_seq_close(seq);
            self.seq = null;
        }
    }

    fn run(self: *MidiIn) void {
        const seq = self.seq.?;

        var pfds: [4]c.struct_pollfd = undefined;
        const npfds = c.snd_seq_poll_descriptors(seq, &pfds, pfds.len, c.POLLIN);
        if (npfds <= 0) return;

        while (self.running.load(.acquire)) {
            // 20 ms timeout: MIDI latency negligible, thread wakes quickly on stop.
            if (c.poll(&pfds, @intCast(npfds), 20) <= 0) continue;

            while (true) {
                var ev_ptr: ?*c.snd_seq_ump_event_t = null;
                const rc = c.snd_seq_ump_event_input(seq, &ev_ptr);
                if (rc < 0) break;
                if (ev_ptr) |ev| self.dispatch(ev);
                if (rc == 0) break; // last pending event consumed
            }
        }
    }

    fn dispatch(self: *MidiIn, ev: *const c.snd_seq_ump_event_t) void {
        if (ev.flags & c.SND_SEQ_EVENT_UMP != 0) {
            if (midi.UmpParser.feed(ev.unnamed_0.ump[0..midi.UmpParser.wordCount(@truncate(ev.unnamed_0.ump[0] >> 28))])) |result|
                if (result.msg) |msg| midi_velocity.dispatchUmp(self, msg);
            return;
        }
        const track = self.active_track.load(.monotonic);
        const eng = self.engine;

        // zig fmt: off
        const etype = @as(c_uint, ev.@"type");

        if (etype == c.SND_SEQ_EVENT_NOTEON) {
            const note: u7 = @intCast(ev.unnamed_0.data.note.note & 0x7F);
            const vel: u7  = @intCast(ev.unnamed_0.data.note.velocity & 0x7F);
            if (vel == 0) {
                _ = eng.sendMidi(.{ .note_off = .{ .track = track, .note = note } });
            } else {
                _ = eng.sendMidi(.{ .note_on = .{
                    .track    = track,
                    .note     = note,
                    .velocity = midi_velocity.apply(self.velocity_curve.load(.monotonic), vel),
                } });
                if (!self.note_queue.push(.{ .pitch = note, .vel = vel }))
                    _ = self.dropped_notes.fetchAdd(1, .monotonic);
            }
        } else if (etype == c.SND_SEQ_EVENT_NOTEOFF) {
            const note: u7 = @intCast(ev.unnamed_0.data.note.note & 0x7F);
            _ = eng.sendMidi(.{ .note_off = .{ .track = track, .note = note } });
        } else if (etype == c.SND_SEQ_EVENT_CONTROLLER) {
            const cc: u7  = @intCast(ev.unnamed_0.data.control.param & 0x7F);
            // zig fmt: on
            const val: u7 = @intCast(ev.unnamed_0.data.control.value & 0x7F);
            // Only mark dirty if the command actually landed - a full
            // queue drops the event, and a false dirty flag would make
            // the project look unsaved over a change that never happened.
            if (eng.sendMidi(.{ .cc = .{ .track = track, .cc = cc, .value = val } }))
                self.dirty.store(true, .release);
        } else if (etype == c.SND_SEQ_EVENT_PITCHBEND) {
            // ALSA delivers pitch bend centred at 0: −8192..+8191.
            const raw = @as(i32, ev.unnamed_0.data.control.value);
            const bend: i16 = @intCast(std.math.clamp(raw, -8192, 8191));
            _ = eng.sendMidi(.{ .pitch_bend = .{ .track = track, .bend = bend } });
        } else if (etype == c.SND_SEQ_EVENT_CHANPRESS) {
            const value = std.math.clamp(@as(i32, ev.unnamed_0.data.control.value), 0, 127);
            _ = eng.sendMidi(.{ .channel_pressure = .{ .track = track, .value = @as(f32, @floatFromInt(value)) / 127.0 } });
        } else if (etype == c.SND_SEQ_EVENT_KEYPRESS) {
            const note: u7 = @intCast(ev.unnamed_0.data.note.note & 0x7F);
            const value: u7 = @intCast(ev.unnamed_0.data.note.velocity & 0x7F);
            _ = eng.sendMidi(.{ .poly_pressure = .{ .track = track, .note = note, .value = @as(f32, @floatFromInt(value)) / 127.0 } });
        } else if (etype == c.SND_SEQ_EVENT_PGMCHANGE) {
            const program: u7 = @intCast(std.math.clamp(@as(i32, ev.unnamed_0.data.control.value), 0, 127));
            _ = eng.sendMidi(.{ .program_change = .{ .track = track, .program = program } });
        }
    }
};

test "an incoming MIDI CC marks dirty; a note does not" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    var midi_in: MidiIn = .{ .engine = &engine };

    var note_ev: c.snd_seq_ump_event_t = std.mem.zeroes(c.snd_seq_ump_event_t);
    // zig fmt: off
    note_ev.@"type" = c.SND_SEQ_EVENT_NOTEON;
    note_ev.unnamed_0.data.note.note = 60;
    note_ev.unnamed_0.data.note.velocity = 100;
    midi_in.dispatch(&note_ev);
    try std.testing.expect(!midi_in.dirty.load(.acquire)); // audition only, nothing persisted changes

    var cc_ev: c.snd_seq_ump_event_t = std.mem.zeroes(c.snd_seq_ump_event_t);
    cc_ev.@"type" = c.SND_SEQ_EVENT_CONTROLLER;
    // zig fmt: on
    cc_ev.unnamed_0.data.control.param = 7; // CC7 -> PolySynth.gain (applyCC), a saved param
    cc_ev.unnamed_0.data.control.value = 100;
    midi_in.dispatch(&cc_ev);
    try std.testing.expect(midi_in.dirty.load(.acquire));
}

test "a note-on queues its pitch + velocity for recording; note-off does not" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    var midi_in: MidiIn = .{ .engine = &engine };

    var on_ev: c.snd_seq_ump_event_t = std.mem.zeroes(c.snd_seq_ump_event_t);
    // zig fmt: off
    on_ev.@"type" = c.SND_SEQ_EVENT_NOTEON;
    on_ev.unnamed_0.data.note.note = 64;
    on_ev.unnamed_0.data.note.velocity = 100;
    midi_in.dispatch(&on_ev);
    try std.testing.expectEqual(@as(?MidiIn.RecNote, .{ .pitch = 64, .vel = 100 }), midi_in.note_queue.pop());
    try std.testing.expectEqual(@as(?MidiIn.RecNote, null), midi_in.note_queue.pop());

    var off_ev: c.snd_seq_ump_event_t = std.mem.zeroes(c.snd_seq_ump_event_t);
    off_ev.@"type" = c.SND_SEQ_EVENT_NOTEOFF;
    off_ev.unnamed_0.data.note.note = 64;
    midi_in.dispatch(&off_ev);
    try std.testing.expectEqual(@as(?MidiIn.RecNote, null), midi_in.note_queue.pop());

    var zero_vel_on: c.snd_seq_ump_event_t = std.mem.zeroes(c.snd_seq_ump_event_t);
    zero_vel_on.@"type" = c.SND_SEQ_EVENT_NOTEON;
    // zig fmt: on
    zero_vel_on.unnamed_0.data.note.note = 64;
    zero_vel_on.unnamed_0.data.note.velocity = 0;
    midi_in.dispatch(&zero_vel_on);
    try std.testing.expectEqual(@as(?MidiIn.RecNote, null), midi_in.note_queue.pop()); // note-on vel=0 is a note-off, not recordable
}

test "ALSA UMP MIDI 2.0 note reaches audition and recording paths" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    var midi_in: MidiIn = .{ .engine = &engine };

    var ev: c.snd_seq_ump_event_t = std.mem.zeroes(c.snd_seq_ump_event_t);
    ev.flags = c.SND_SEQ_EVENT_UMP;
    ev.unnamed_0.ump[0] = 0x40903C00;
    ev.unnamed_0.ump[1] = 0x80000000;
    midi_in.dispatch(&ev);

    try std.testing.expectEqual(@as(?MidiIn.RecNote, .{ .pitch = 60, .vel = 64 }), midi_in.note_queue.pop());
}

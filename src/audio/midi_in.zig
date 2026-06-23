//! ALSA Sequencer MIDI input. Opens a virtual port, spawns a reader thread,
//! and pushes Engine Commands for every incoming note, CC, and pitch-bend.
//!
//! Connect a hardware device with:  aconnect <device> wstudio:0
//! List available devices with:     aconnect -l

const std = @import("std");
const Engine = @import("engine.zig").Engine;

const c = @cImport(@cInclude("alsa/asoundlib.h"));

pub const MidiIn = struct {
    seq: ?*c.snd_seq_t = null,
    port: c_int = -1,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),
    engine: *Engine,
    /// Engine track index that receives all incoming MIDI. Write from UI thread.
    active_track: std.atomic.Value(u16) = .init(0),

    pub const Error = error{ SeqOpenFailed, PortCreateFailed, ThreadSpawnFailed };

    pub fn start(self: *MidiIn) Error!void {
        if (c.snd_seq_open(&self.seq, "default", c.SND_SEQ_OPEN_INPUT, 0) < 0)
            return error.SeqOpenFailed;
        errdefer {
            _ = c.snd_seq_close(self.seq);
            self.seq = null;
        }

        _ = c.snd_seq_set_client_name(self.seq, "wstudio");

        const port = c.snd_seq_create_simple_port(
            self.seq,
            "MIDI In",
            c.SND_SEQ_PORT_CAP_WRITE | c.SND_SEQ_PORT_CAP_SUBS_WRITE,
            c.SND_SEQ_PORT_TYPE_APPLICATION,
        );
        if (port < 0) return error.PortCreateFailed;
        self.port = port;

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
                var ev_ptr: ?*c.snd_seq_event_t = null;
                const rc = c.snd_seq_event_input(seq, &ev_ptr);
                if (rc < 0) break;
                if (ev_ptr) |ev| self.dispatch(ev);
                if (rc == 0) break; // last pending event consumed
            }
        }
    }

    fn dispatch(self: *MidiIn, ev: *const c.snd_seq_event_t) void {
        const track = self.active_track.load(.monotonic);
        const eng = self.engine;

        const etype = @as(c_uint, ev.@"type");

        if (etype == c.SND_SEQ_EVENT_NOTEON) {
            const note: u7 = @intCast(ev.data.note.note & 0x7F);
            const vel: u7  = @intCast(ev.data.note.velocity & 0x7F);
            if (vel == 0) {
                _ = eng.send(.{ .note_off = .{ .track = track, .note = note } });
            } else {
                _ = eng.send(.{ .note_on = .{
                    .track    = track,
                    .note     = note,
                    .velocity = @as(f32, @floatFromInt(vel)) / 127.0,
                } });
            }
        } else if (etype == c.SND_SEQ_EVENT_NOTEOFF) {
            const note: u7 = @intCast(ev.data.note.note & 0x7F);
            _ = eng.send(.{ .note_off = .{ .track = track, .note = note } });
        } else if (etype == c.SND_SEQ_EVENT_CONTROLLER) {
            const cc: u7  = @intCast(ev.data.control.param & 0x7F);
            const val: u7 = @intCast(ev.data.control.value & 0x7F);
            _ = eng.send(.{ .cc = .{ .track = track, .cc = cc, .value = val } });
        } else if (etype == c.SND_SEQ_EVENT_PITCHBEND) {
            // ALSA delivers pitch bend centred at 0: −8192..+8191.
            const raw = @as(i32, ev.data.control.value);
            const bend: i16 = @intCast(std.math.clamp(raw, -8192, 8191));
            _ = eng.send(.{ .pitch_bend = .{ .track = track, .bend = bend } });
        }
    }
};

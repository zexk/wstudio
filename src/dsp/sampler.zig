//! Single-clip chromatic sampler - the melodic counterpart to the drum
//! machine. One sample is held in a `Pad` and played back polyphonically:
//! each MIDI note triggers a voice pitched by `(note - root_note)` semitones
//! on top of the pad's own transpose. Voices are one-shots by default
//! (note-off is ignored); the amp ADSR and region trim shape the tail. Set
//! the pad's `gate` flag to make note-off release instead, so piano-roll note
//! lengths actually shorten the sample.
//!
//! The heavy lifting - fractional pitched reads, region trim, reverse, ADSR,
//! pan - is shared with the drum machine via `pad.renderVoice`, so a
//! Sampler is effectively a thin shim over the same Pad/Voice engine. Per-clip
//! params are plain scalars nudged on the audio thread via the `set_param`
//! device event (race-free, same path the synth and drum editors use).

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const pad_dsp = @import("pad.zig");
const tuning_mod = @import("tuning.zig");
const Pad = pad_dsp.Pad;
const Voice = pad_dsp.Voice;
const pitch = @import("pitch.zig");
const tempo = @import("tempo.zig");

const Sample = types.Sample;

pub const Sampler = struct {
    pub const max_voices: u8 = 16;
    /// Number of editable params (see `adjustParam`).
    pub const param_count: u16 = pad_dsp.param_count + 2;
    /// Sampler-only param ids, appended past `pad.zig`'s shared table.
    pub const root_note_id: u16 = pad_dsp.param_count;
    pub const mono_id: u16 = pad_dsp.param_count + 1;

    pub const NoteVoice = struct {
        active: bool = false,
        note: u7 = 0,
        /// Pitch offset from the pad's base transpose, in semitones.
        semis: f32 = 0,
        /// Monotonic trigger order, for oldest-voice stealing.
        age: u64 = 0,
        v: Voice = .{},
    };

    allocator: std.mem.Allocator,
    sample_rate: u32,

    /// Guards `pad.samples` against concurrent reads (audio thread) and writes
    /// (control thread calling loadWav at runtime). Mirrors DrumMachine.
    pad_lock: std.atomic.Mutex = .unlocked,
    /// The clip plus its shared sampler params (gain/pan/pitch/trim/ADSR).
    pad: Pad,
    /// MIDI note at which the clip plays at its native pitch.
    root_note: u7 = 60,
    /// Tempo and root pitch class the loaded clip's file name declared, on
    /// the same terms (and with the same not-saved caveat) as
    /// `Slicer.clip_bpm`/`clip_root`.
    clip_bpm: f32 = 0,
    clip_root: ?u4 = null,
    /// Project temperament - see `PolySynth.tuning` for the field's contract
    /// and why the unsynchronized write is safe. A melodic sampler is played
    /// against a tonal centre like any other pitched instrument, so it has
    /// to follow the same one the synths do.
    tuning: tuning_mod.Tuning = .{},
    /// Mono voice mode: a retrigger cuts every other still-ringing voice
    /// first, so overlapping one-shots (e.g. a held 808 bass note replayed
    /// before it decays) don't stack. Off by default (polyphonic).
    mono: bool = false,

    // Audio-thread-only state:
    voices: [max_voices]NoteVoice,
    /// Monotonic trigger counter for voice-stealing order.
    next_age: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32) !Sampler {
        return .{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .pad = .{ .samples = try allocator.alloc(f32, 0) },
            .voices = [_]NoteVoice{.{}} ** max_voices,
        };
    }

    pub fn deinit(self: *Sampler) void {
        self.allocator.free(self.pad.samples);
    }

    /// Deep copy for track duplication: the clip audio gets a fresh
    /// allocation so the two samplers share no memory. Voice state resets -
    /// there are no mid-flight notes worth carrying over.
    pub fn dupe(self: *const Sampler) !Sampler {
        var copy = self.*;
        copy.pad.samples = try self.allocator.dupe(f32, self.pad.samples);
        copy.pad_lock = .unlocked;
        copy.voices = [_]NoteVoice{.{}} ** max_voices;
        copy.next_age = 0;
        return copy;
    }

    pub const device = dsp.deviceOf(@This());

    pub fn clipName(self: *const Sampler) []const u8 {
        return pad_dsp.trimmedName(&self.pad.name);
    }

    /// Set the display name directly, independent of the loaded audio -
    /// unlike `loadWav`/`setSamples`, doesn't touch `pad.samples` or
    /// `user_sample`. Truncated to 8 chars like every other name setter here.
    pub fn rename(self: *Sampler, name: []const u8) void {
        while (!self.pad_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.pad_lock.unlock();
        self.pad.name = pad_dsp.fixedName(name);
    }

    // -----------------------------------------------------------------------
    // Param editing - `id` is the param index (single pad, no pad nibble).

    /// Nudge param `id` by `steps` (h/l = ±1, H/L = ±10). Runs on the audio
    /// thread via the `set_param` event so it never races the block reader.
    /// Ids 0-14 (region/pitch/ADSR/gain/pan/reverse/fades/stretch/filter/gate)
    /// delegate to `pad.zig`'s shared clamp table; `root_note_id`/`mono_id`
    /// past it are Sampler-only. Session-scoped ids - nothing persisted stores
    /// them, so root/mono sliding up as the shared table grows costs nothing
    /// (same as when stretch landed at 12, and fades at 10/11 before it).
    pub fn adjustParam(self: *Sampler, id: u16, steps: i32) void {
        if (id < pad_dsp.param_count) {
            pad_dsp.adjustParam(&self.pad, id, steps);
            if (pad_dsp.affectsTimeRange(id)) pad_dsp.clampTimeParamsToDuration(&self.pad, self.sample_rate);
        } else if (id == root_note_id) {
            const r = @as(i32, self.root_note) + steps;
            self.root_note = @intCast(std.math.clamp(r, 0, 127));
        } else if (id == mono_id and steps != 0) {
            self.mono = !self.mono;
        }
    }

    /// Absolute-value counterpart to `adjustParam`, same id space and clamp
    /// ranges - for undo's capture/restore (`paramValue` is the read half),
    /// mirroring PolySynth's own pair. Toggles (reverse, gate, mono): >= 0.5
    /// is on. Runs on the audio thread via the `set_param_abs` event.
    pub fn setParamAbsolute(self: *Sampler, id: u16, value: f32) void {
        if (id < pad_dsp.param_count) {
            pad_dsp.setParamAbsolute(&self.pad, id, value);
            if (pad_dsp.affectsTimeRange(id)) pad_dsp.clampTimeParamsToDuration(&self.pad, self.sample_rate);
        } else if (id == root_note_id) {
            if (!(value > 0.0)) { // also catches NaN
                self.root_note = 0;
            } else if (value >= 127.0) {
                self.root_note = 127;
            } else {
                self.root_note = @intFromFloat(@round(value));
            }
        } else if (id == mono_id) {
            self.mono = value >= 0.5;
        }
    }

    /// Current value of param `id`, same unit/encoding `setParamAbsolute`
    /// accepts (toggles as 0/1) - the read half of undo's capture/restore
    /// pair. A control-thread read of live fields, same race-tolerant
    /// convention the sampler editor's own row rendering already uses.
    pub fn paramValue(self: *const Sampler, id: u16) ?f32 {
        if (id < pad_dsp.param_count) return pad_dsp.paramValue(&self.pad, id);
        if (id == root_note_id) return @floatFromInt(self.root_note);
        if (id == mono_id) return if (self.mono) 1.0 else 0.0;
        return null;
    }

    /// One entry per continuous `setParamAbsolute`-handled id - same shape
    /// and purpose as PolySynth's own table (`dsp.AutomatableParam`), for the
    /// automation editor's param picker/curve labels/h-l nudge step. Toggles
    /// (reverse, gate, mono) and root_note are deliberately excluded, same
    /// call PolySynth's own table already made for its enum/toggle ids
    /// (waveform, osc-B on/off, ...) - a breakpoint curve over an on/off
    /// flip or a coarse tuning offset isn't a meaningful automation target.
    pub const automatable_params = [_]dsp.AutomatableParam{
        // zig fmt: off
        .{ .id = 0, .label = "START",   .section = "SAMPLE",  .range = .{ 0.0,   1.0 }, .step = 0.01 },
        .{ .id = 1, .label = "END",     .section = "SAMPLE",  .range = .{ 0.0,   1.0 }, .step = 0.01 },
        .{ .id = 2, .label = "PITCH",   .section = "SAMPLE",  .range = .{ -24.0, 24.0 }, .step = 1.0 },
        .{ .id = 3, .label = "ATTACK",  .section = "AMP ENV", .range = .{ 0.0,   5.0 }, .step = 0.001 },
        .{ .id = 4, .label = "DECAY",   .section = "AMP ENV", .range = .{ 0.0,   5.0 }, .step = 0.005 },
        .{ .id = 5, .label = "SUSTAIN", .section = "AMP ENV", .range = .{ 0.0,   1.0 }, .step = 0.01 },
        .{ .id = 6, .label = "RELEASE", .section = "AMP ENV", .range = .{ 0.001, 5.0 }, .step = 0.005 },
        .{ .id = 7, .label = "GAIN",    .section = "OUT",     .range = .{ 0.0,   2.0 }, .step = 0.01 },
        .{ .id = 8, .label = "PAN",     .section = "OUT",     .range = .{ -1.0,  1.0 }, .step = 0.05 },
        .{ .id = 10, .label = "FADE IN",  .section = "FADE",  .range = .{ 0.0,   5.0 }, .step = 0.005 },
        .{ .id = 11, .label = "FADE OUT", .section = "FADE",  .range = .{ 0.0,   5.0 }, .step = 0.005 },
        .{ .id = 12, .label = "STRETCH",  .section = "SAMPLE", .range = .{ 0.25,  4.0 }, .step = 0.05 },
        .{ .id = 13, .label = "FILTER",   .section = "OUT",   .range = .{ -1.0,  1.0 }, .step = 0.02 },
        // zig fmt: on
    };

    pub fn findAutomatableParam(id: u16) ?*const dsp.AutomatableParam {
        for (&automatable_params) |*p| if (p.id == id) return p;
        return null;
    }

    // -----------------------------------------------------------------------
    // Sample loading (call from control side only, not while audio thread runs)

    /// Parse raw WAV bytes into the clip, keeping every other pad param as-is.
    /// Resamples to engine rate if needed.
    pub fn loadWav(self: *Sampler, wav_data: []const u8, name: []const u8) !void {
        const samples = try pad_dsp.decodeWav(self.allocator, wav_data, self.sample_rate);

        while (!self.pad_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.pad_lock.unlock();
        self.allocator.free(self.pad.samples);
        self.pad.samples = samples;
        self.pad.name = pad_dsp.fixedName(name);
        // Read before `fixedName` throws the rest of the name away.
        self.clip_bpm = tempo.bpmFromName(name) orelse 0;
        self.clip_root = pitch.rootFromName(name);
        pad_dsp.clampTimeParamsToDuration(&self.pad, self.sample_rate);
        self.resetAll();
    }

    /// Guess the root note from the currently loaded clip via YIN pitch
    /// detection (see `dsp/pitch.zig`) and, if confident, set `root_note` to
    /// it. Returns the detection result so callers (the `:load`
    /// command) can report it; returns null and leaves `root_note` untouched
    /// for percussive/noisy material with no clear single pitch. Not called
    /// from `loadWav` itself - project-file restores set `root_note` from
    /// the save explicitly and shouldn't pay for/override that with a fresh
    /// detection pass.
    pub fn detectRootNote(self: *Sampler) ?pitch.Result {
        const r = pitch.detect(self.pad.samples, self.sample_rate) orelse return null;
        self.root_note = r.note;
        return r;
    }

    /// Replace the clip with already-decoded samples, resetting every other
    /// pad param to its default (gain 1.0, unity trim, flat ADSR, etc). Used
    /// when a caller wants a clean slate rather than `loadWav`'s in-place swap
    /// - e.g. procedurally generated kit pads.
    pub fn setSamples(self: *Sampler, samples: []f32, name: []const u8) void {
        while (!self.pad_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.pad_lock.unlock();
        self.allocator.free(self.pad.samples);
        self.pad = .{ .samples = samples, .gain = 1.0, .name = pad_dsp.fixedName(name) };
        pad_dsp.clampTimeParamsToDuration(&self.pad, self.sample_rate);
        self.resetAll();
    }

    // -----------------------------------------------------------------------
    // Audio thread processing

    /// Trigger a one-shot voice at `note` (chromatic offset from `root_note`),
    /// `vel` (0..1, applied on top of the pad gain) starting `block_start`
    /// frames into the next `processBlock` call. Runs on the audio thread via
    /// the `note_on` device event; also called directly by DrumMachine, whose
    /// pads are plain embedded Samplers.
    pub fn trigger(self: *Sampler, note: u7, vel: f32, block_start: u32) void {
        self.triggerHeld(note, vel, block_start, -1.0);
    }

    /// `trigger` carrying the sequencer's per-note expression - the
    /// sampler's half of `PolySynth.noteOnArt`, split from `trigger` for the
    /// same reason: a pad hit, a drum step and an audition have none.
    pub fn triggerArt(self: *Sampler, note: u7, vel: f32, block_start: u32, art: dsp.Articulation) void {
        self.triggerHeldArt(note, vel, block_start, -1.0, art);
    }

    /// `trigger` with a gated hold: how long a gated pad (`Pad.gate`) plays
    /// before releasing itself, in output frames - see `pad.Voice.hold_frames`.
    /// A step sequencer has no note-off to send, so it passes its step's own
    /// length here; anything holding a key passes -1 and waits for the
    /// note-off instead.
    pub fn triggerHeld(self: *Sampler, note: u7, vel: f32, block_start: u32, hold: f64) void {
        self.triggerHeldArt(note, vel, block_start, hold, .neutral);
    }

    pub fn triggerHeldArt(self: *Sampler, note: u7, vel: f32, block_start: u32, hold: f64, art: dsp.Articulation) void {
        // Mono mode (and the pad's own `.retrigger` play mode): a new note
        // always cuts every still-ringing voice first, so long one-shots
        // (e.g. a bass note) never overlap themselves. What they were
        // collectively writing is carried onto the new voice and faded out,
        // so the cut is a ramp rather than a step.
        var cut_l: f32 = 0.0;
        var cut_r: f32 = 0.0;
        if (self.mono or self.pad.retrig) {
            for (&self.voices) |*nv| if (nv.active) {
                cut_l += nv.v.prev_l;
                cut_r += nv.v.prev_r;
            };
            self.resetAll();
        }

        // The stolen voice's last pair is faded out over the new one's first
        // ~1ms (`pad_dsp.carryStealTail`), the same declick PolySynth and
        // SoundfontPlayer voices get.
        // Reuse a free voice, else steal - preferring one already released
        // (a gated pad past its note-off) over one still holding its key, so
        // a held note isn't cut while an inaudible tail survives. Age breaks
        // ties within each group. A latched one-shot pad never sets
        // `release_frames`, so it falls back to plain oldest-first.
        var slot: usize = 0;
        var oldest_age: u64 = std.math.maxInt(u64);
        var stealing_released = false;
        for (&self.voices, 0..) |*nv, i| {
            if (!nv.active) {
                slot = i;
                break;
            }
            const released = nv.v.release_frames >= 0.0;
            const better = (released and !stealing_released) or
                (released == stealing_released and nv.age < oldest_age);
            if (better) {
                stealing_released = released;
                oldest_age = nv.age;
                slot = i;
            }
        }
        const stolen = self.voices[slot].v;
        self.voices[slot] = .{
            .active = true,
            .note = note,
            .semis = @as(f32, @floatFromInt(@as(i16, note) - @as(i16, self.root_note))) +
                self.tuning.offsetCents(note) / 100.0,
            .age = self.next_age,
            .v = .{ .active = true, .played = 0, .block_start = block_start, .vel = vel, .hold_frames = hold, .art = art },
        };
        pad_dsp.carryStealTail(&self.voices[slot].v, stolen);
        pad_dsp.carryTailPair(&self.voices[slot].v, cut_l, cut_r);
        self.next_age +%= 1;
    }

    /// Release the oldest voice still holding `note`. Only a gated pad
    /// (`Pad.gate`) actually acts on it - a latched one-shot renders the flag
    /// inert and plays out regardless, which is the default and matches how
    /// this sampler has always behaved.
    pub fn releaseNote(self: *Sampler, note: u7) void {
        var oldest: ?*NoteVoice = null;
        for (&self.voices) |*nv| {
            if (!nv.active or nv.note != note or nv.v.release_frames >= 0.0) continue;
            if (oldest == null or nv.age < oldest.?.age) oldest = nv;
        }
        if (oldest) |nv| pad_dsp.release(&nv.v);
    }

    pub fn processBlock(self: *Sampler, buf: []Sample) void {
        const channels = 2;
        const frames: u32 = @intCast(buf.len / channels);
        const sr: f64 = @floatFromInt(self.sample_rate);

        // Sample swaps run on control thread. Missing one render block is
        // safer than making audio callback wait for decode/load cleanup.
        if (!self.pad_lock.tryLock()) return;
        defer self.pad_lock.unlock();

        // One shared LFO phase per block, read by every simultaneously
        // active voice below (each copies it into its own `eff` snapshot) -
        // ticking once here, not per-voice, is what keeps polyphonic notes
        // on this pad in phase with each other.
        pad_dsp.tickModLfo(&self.pad, sr);

        for (&self.voices) |*nv| {
            if (!nv.active) continue;
            // A voice triggered mid-block (a step fired at `fire_frame`,
            // see DrumMachine.processBlock) keeps its `block_start` offset
            // for this first render; renderVoice itself resets it to 0
            // once consumed, so voices surviving into later blocks render
            // from the top. Zeroing it here instead used to flatten every
            // step onto the block boundary, quantizing swing/step timing
            // to ~block granularity.
            // Effective pad: pad params + this voice's chromatic transpose.
            // The value copy shares the `samples` slice (no allocation).
            var eff = self.pad;
            eff.pitch_semitones = std.math.clamp(self.pad.pitch_semitones + nv.semis, -60.0, 60.0);
            pad_dsp.renderVoice(&nv.v, &eff, buf, channels, frames, sr);
            if (!nv.v.active) nv.active = false;
        }
    }

    pub fn resetAll(self: *Sampler) void {
        for (&self.voices) |*nv| nv.* = .{};
    }

    /// `deviceOf`'s expected name; forwards to `resetAll` since a Sampler
    /// has exactly one thing to reset (its voices).
    pub fn reset(self: *Sampler) void {
        self.resetAll();
    }

    pub fn handleEvent(self: *Sampler, ev: dsp.Event) void {
        switch (ev) {
            // zig fmt: off
            .note_on   => |e| self.triggerArt(e.note, e.velocity, 0, e.art),
            .note_off  => |e| self.releaseNote(e.note),
            // e.id is u16 (wide enough for DrumMachine's pad-encoded ids);
            // truncate rather than @intCast, same reasoning as PolySynth's
            // identical arm.
            .set_param => |e| self.adjustParam(e.id, e.steps),
            .set_param_abs => |e| self.setParamAbsolute(e.id, e.value),
            .automation_param => |e| if (e.instance_id == 0 and e.id <= std.math.maxInt(u16)) self.setParamAbsolute(@intCast(e.id), e.value),
            .cc, .pitch_bend, .set_mod_target, .clap_param, .vst3_param, .set_sidechain_buf, .capture_pad => {},
            .all_off   => self.resetAll(),
            // zig fmt: on
        }
    }
};

fn generateTestClip(allocator: std.mem.Allocator, sample_rate: u32) ![]f32 {
    const sr: f32 = @floatFromInt(sample_rate);
    const len: usize = @intFromFloat(sr * 0.6);
    const out = try allocator.alloc(f32, len);
    const freq: f32 = 261.6256; // C4
    const tau: f32 = 0.18; // decay time constant
    for (out, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / sr;
        const env = @exp(-t / tau);
        const phase = 2.0 * std.math.pi * freq * t;
        // Fundamental plus a quieter octave for a little body.
        s.* = env * (0.9 * @sin(phase) + 0.2 * @sin(2.0 * phase));
    }
    return out;
}

test "processBlock skips pad-lock contention" {
    var s = try Sampler.init(std.testing.allocator, 48_000);
    defer s.deinit();
    try std.testing.expect(s.pad_lock.tryLock());
    defer s.pad_lock.unlock();
    var buf = [_]Sample{ 1, 1 };
    s.processBlock(&buf);
    try std.testing.expectEqualSlices(Sample, &.{ 1, 1 }, &buf);
}

// -----------------------------------------------------------------------
// Tests

test "sampler starts with no sample" {
    var s = try Sampler.init(std.testing.allocator, 48_000);
    defer s.deinit();

    try std.testing.expectEqual(@as(usize, 0), s.pad.samples.len);
    try std.testing.expectEqualStrings("", s.clipName());
}

test "loaded sampler is audible at root note" {
    var s = try Sampler.init(std.testing.allocator, 48_000);
    defer s.deinit();
    s.setSamples(try generateTestClip(std.testing.allocator, 48_000), "tone");

    const dev = s.device();
    dev.sendEvent(.{ .note_on = .{ .note = 60, .velocity = 1.0 } });

    var buf: [512]Sample = undefined;
    @memset(&buf, 0.0);
    dev.process(&buf);

    var peak: f32 = 0;
    for (buf) |x| peak = @max(peak, @abs(x));
    try std.testing.expect(peak > 0.01);
}

test "higher note plays back faster (chromatic transpose)" {
    var s = try Sampler.init(std.testing.allocator, 48_000);
    defer s.deinit();
    s.setSamples(try generateTestClip(std.testing.allocator, 48_000), "tone");

    // An octave up consumes the region twice as fast, so its voice deactivates
    // in fewer blocks than the root note.
    const blocks_to_finish = struct {
        fn run(smp: *Sampler, note: u7) usize {
            smp.resetAll();
            smp.trigger(note, 1.0, 0);
            var buf: [512]Sample = undefined;
            var n: usize = 0;
            while (smp.voices[0].active and n < 10_000) : (n += 1) {
                @memset(&buf, 0.0);
                smp.processBlock(&buf);
            }
            return n;
        }
    }.run;

    const root_blocks = blocks_to_finish(&s, 60);
    const oct_blocks = blocks_to_finish(&s, 72);
    try std.testing.expect(oct_blocks < root_blocks);
}

test "stretch_ratio scales playback duration" {
    var s = try Sampler.init(std.testing.allocator, 48_000);
    defer s.deinit();
    s.setSamples(try generateTestClip(std.testing.allocator, 48_000), "tone");

    const blocks_to_finish = struct {
        fn run(smp: *Sampler, stretch: f32, method: pad_dsp.WarpMethod) usize {
            smp.resetAll();
            smp.pad.stretch_ratio = stretch;
            smp.pad.warp_method = method;
            smp.trigger(60, 1.0, 0);
            var buf: [512]Sample = undefined;
            var n: usize = 0;
            while (smp.voices[0].active and n < 10_000) : (n += 1) {
                @memset(&buf, 0.0);
                smp.processBlock(&buf);
            }
            return n;
        }
    }.run;

    for ([_]pad_dsp.WarpMethod{ .beats, .tones }) |method| {
        const base_blocks = blocks_to_finish(&s, 1.0, method);
        const stretched_blocks = blocks_to_finish(&s, 2.0, method);
        const ratio = @as(f64, @floatFromInt(stretched_blocks)) / @as(f64, @floatFromInt(base_blocks));
        try std.testing.expect(ratio > 1.9 and ratio < 2.1);
    }
}

test "stretch_ratio composes with pitch to preserve duration while shifting pitch" {
    var s = try Sampler.init(std.testing.allocator, 48_000);
    defer s.deinit();
    s.setSamples(try generateTestClip(std.testing.allocator, 48_000), "tone");

    const Result = struct { blocks: usize, frames: usize };
    const render = struct {
        fn run(smp: *Sampler, semis: f32, stretch: f32, out: []f32) Result {
            smp.resetAll();
            smp.pad.pitch_semitones = semis;
            smp.pad.stretch_ratio = stretch;
            smp.trigger(60, 1.0, 0);
            var buf: [512]Sample = undefined;
            var n: usize = 0;
            var written: usize = 0;
            while (smp.voices[0].active and n < 10_000) : (n += 1) {
                @memset(&buf, 0.0);
                smp.processBlock(&buf);
                var i: usize = 0;
                while (i < 256 and written < out.len) : (i += 1) {
                    out[written] = buf[i * 2]; // left channel
                    written += 1;
                }
            }
            return .{ .blocks = n, .frames = written };
        }
    }.run;

    // Baseline: unshifted duration in blocks - only the count is needed here.
    var dummy: [1]f32 = undefined;
    const base = render(&s, 0.0, 1.0, &dummy);

    // +1 octave (rate=2) with stretch_ratio matching that same rate cancels
    // the tied speed change (duration ~ stretch_ratio/rate), so this should
    // finish in roughly the baseline's block count while still sounding an
    // octave higher.
    var shifted_buf: [96_000]f32 = undefined;
    const shifted = render(&s, 12.0, 2.0, &shifted_buf);

    const ratio = @as(f64, @floatFromInt(shifted.blocks)) / @as(f64, @floatFromInt(base.blocks));
    try std.testing.expect(ratio > 0.8 and ratio < 1.2);

    const analyze_len = @min(shifted.frames, 20_000);
    const r = pitch.detect(shifted_buf[0..analyze_len], 48_000) orelse return error.NoPitchDetected;
    try std.testing.expectEqual(@as(u7, 72), r.note);
}

test "all_off clears voices" {
    var s = try Sampler.init(std.testing.allocator, 48_000);
    defer s.deinit();
    s.trigger(64, 1.0, 0);
    try std.testing.expect(s.voices[0].active);
    s.device().sendEvent(.all_off);
    try std.testing.expect(!s.voices[0].active);
}

test "replacing the sample clears voices tied to the old clip" {
    var s = try Sampler.init(std.testing.allocator, 48_000);
    defer s.deinit();
    s.setSamples(try generateTestClip(std.testing.allocator, 48_000), "old");
    s.trigger(60, 1.0, 0);
    try std.testing.expect(s.voices[0].active);

    s.setSamples(try generateTestClip(std.testing.allocator, 48_000), "new");
    for (s.voices) |voice| try std.testing.expect(!voice.active);
}

test "mono mode chokes a still-ringing voice on retrigger" {
    var s = try Sampler.init(std.testing.allocator, 48_000);
    defer s.deinit();

    // Polyphonic by default: two overlapping triggers hold two active voices.
    s.trigger(60, 1.0, 0);
    s.trigger(64, 1.0, 0);
    try std.testing.expect(s.voices[0].active);
    try std.testing.expect(s.voices[1].active);

    s.resetAll();
    s.mono = true;
    s.trigger(60, 1.0, 0);
    try std.testing.expect(s.voices[0].active);
    s.trigger(64, 1.0, 0);
    // The first voice was choked by the second trigger; only one is active.
    var active_count: usize = 0;
    // zig fmt: off
    for (s.voices) |nv| { if (nv.active) active_count += 1; }
    // zig fmt: on
    try std.testing.expectEqual(@as(usize, 1), active_count);
}

test "note-off releases only oldest same-pitch voice" {
    var s = try Sampler.init(std.testing.allocator, 48_000);
    defer s.deinit();
    s.pad.gate = true;
    s.trigger(60, 1.0, 0);
    s.trigger(60, 1.0, 0);

    s.releaseNote(60);
    try std.testing.expectEqual(@as(f64, 0.0), s.voices[0].v.release_frames);
    try std.testing.expect(s.voices[1].v.release_frames < 0.0);
    s.releaseNote(60);
    try std.testing.expectEqual(@as(f64, 0.0), s.voices[1].v.release_frames);
}

test "voice stealing takes a released voice before a still-held older one" {
    var s = try Sampler.init(std.testing.allocator, 48_000);
    defer s.deinit();
    s.pad.gate = true;

    // Fill every slot: note 40 is the oldest, note 41 the second oldest.
    const base: u7 = 40;
    for (0..Sampler.max_voices) |i| s.trigger(base + @as(u7, @intCast(i)), 1.0, 0);
    for (s.voices) |nv| try std.testing.expect(nv.active);

    s.releaseNote(base + 1);
    s.trigger(100, 1.0, 0);

    var saw_oldest = false;
    var saw_released = false;
    var saw_new = false;
    for (s.voices) |nv| {
        if (!nv.active) continue;
        if (nv.note == base) saw_oldest = true;
        if (nv.note == base + 1) saw_released = true;
        if (nv.note == 100) saw_new = true;
    }
    try std.testing.expect(saw_new);
    try std.testing.expect(saw_oldest);
    try std.testing.expect(!saw_released);
}

test "detectRootNote sets root_note from a melodic clip" {
    var s = try Sampler.init(std.testing.allocator, 48_000);
    defer s.deinit();

    const clip = try std.testing.allocator.alloc(f32, 24_000); // 0.5s @ 48kHz
    defer std.testing.allocator.free(clip);
    const freq: f32 = 220.0; // A3
    for (clip, 0..) |*v, i| {
        const t = @as(f32, @floatFromInt(i)) / 48_000.0;
        v.* = @sin(2.0 * std.math.pi * freq * t);
    }
    s.setSamples(try std.testing.allocator.dupe(f32, clip), "a3tone");

    s.root_note = 60; // starts elsewhere so the assertion is meaningful
    const r = s.detectRootNote() orelse return error.NoPitchDetected;
    try std.testing.expectEqual(@as(u7, 57), r.note); // A3 = MIDI 57
    try std.testing.expectEqual(@as(u7, 57), s.root_note);
}

test "detectRootNote leaves root_note alone on noisy material" {
    var s = try Sampler.init(std.testing.allocator, 48_000);
    defer s.deinit();

    const clip = try std.testing.allocator.alloc(f32, 24_000);
    defer std.testing.allocator.free(clip);
    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    for (clip) |*v| v.* = rand.float(f32) * 2.0 - 1.0;
    s.setSamples(try std.testing.allocator.dupe(f32, clip), "noise");

    s.root_note = 60;
    try std.testing.expectEqual(@as(?pitch.Result, null), s.detectRootNote());
    try std.testing.expectEqual(@as(u7, 60), s.root_note);
}

test "adjustParam toggles mono" {
    var s = try Sampler.init(std.testing.allocator, 48_000);
    defer s.deinit();
    try std.testing.expect(!s.mono);
    s.adjustParam(Sampler.mono_id, 1);
    try std.testing.expect(s.mono);
    s.adjustParam(Sampler.mono_id, -1);
    try std.testing.expect(!s.mono);
    s.adjustParam(Sampler.mono_id, 0); // steps=0 is a no-op, mirroring the reverse toggle
    try std.testing.expect(!s.mono);
}

test "adjustParam edits clip params and root note" {
    var s = try Sampler.init(std.testing.allocator, 48_000);
    defer s.deinit();
    s.adjustParam(2, 5); // pitch +5 semis
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), s.pad.pitch_semitones, 1e-4);
    s.adjustParam(Sampler.root_note_id, -12); // root down an octave
    try std.testing.expectEqual(@as(u7, 48), s.root_note);
    s.adjustParam(9, 1); // reverse toggle
    try std.testing.expect(s.pad.reverse);
    s.adjustParam(10, 4); // cubic travel keeps short fades easy to reach
    try std.testing.expectApproxEqAbs(@as(f32, 0.04), s.pad.fade_in_s, 1e-4);
    s.adjustParam(11, 4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.04), s.pad.fade_out_s, 1e-4);
}

test "a mid-block trigger renders from its block_start offset, not the block top" {
    var s = try Sampler.init(std.testing.allocator, 48_000);
    defer s.deinit();
    s.setSamples(try generateTestClip(std.testing.allocator, 48_000), "tone");

    s.trigger(s.root_note, 1.0, 100); // fire 100 frames into the block
    var buf: [512]Sample = undefined; // 256 frames stereo
    @memset(&buf, 0.0);
    s.processBlock(&buf);

    // Everything before the offset stays silent; the hit starts at it.
    for (buf[0 .. 100 * 2]) |x| try std.testing.expectEqual(@as(Sample, 0.0), x);
    var peak: f32 = 0.0;
    for (buf[100 * 2 ..]) |x| peak = @max(peak, @abs(x));
    try std.testing.expect(peak > 0.001);

    // The offset is consumed: the next block renders from its own top.
    @memset(&buf, 0.0);
    s.processBlock(&buf);
    var head: f32 = 0.0;
    for (buf[0..16]) |x| head = @max(head, @abs(x));
    try std.testing.expect(head > 0.0001);
}

test "a mono retrigger ramps the cut voices out instead of stepping to the new one" {
    var s = try Sampler.init(std.testing.allocator, 48_000);
    defer s.deinit();
    s.setSamples(try generateTestClip(std.testing.allocator, 48_000), "tone");
    s.pad.attack_s = 0.0;
    s.mono = true;

    var buf = [_]Sample{0.0} ** 512;
    s.triggerHeld(60, 1.0, 0, -1.0);
    s.processBlock(&buf);
    const ringing = s.voices[0].v.prev_l;
    try std.testing.expect(@abs(ringing) > 0.0);

    // The retrigger wipes that voice; the new one carries its last pair.
    s.triggerHeld(60, 1.0, 0, -1.0);
    try std.testing.expectEqual(ringing, s.voices[0].v.steal_tail_l);
    try std.testing.expectEqual(@as(f32, 1.0), s.voices[0].v.steal_fade);

    @memset(&buf, 0.0);
    s.processBlock(&buf);
    try std.testing.expectEqual(@as(f32, 0), s.voices[0].v.steal_fade);
}

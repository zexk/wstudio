//! Single-clip chromatic sampler - the melodic counterpart to the drum
//! machine. One sample is held in a `Pad` and played back polyphonically:
//! each MIDI note triggers a voice pitched by `(note - root_note)` semitones
//! on top of the pad's own transpose. Voices are one-shots (note-off is
//! ignored); the amp ADSR and region trim shape the tail.
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
const Pad = pad_dsp.Pad;
const Voice = pad_dsp.Voice;
const pitch = @import("pitch.zig");

const Sample = types.Sample;

pub const Sampler = struct {
    pub const max_voices: u8 = 16;
    /// Number of editable params (see `adjustParam`).
    pub const param_count: u8 = 12;

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
    /// Ids 0-9 (region/pitch/ADSR/gain/pan/reverse) delegate to `pad.zig`'s
    /// shared clamp table; 10-11 (root_note/mono) are Sampler-only.
    pub fn adjustParam(self: *Sampler, id: u8, steps: i32) void {
        switch (id) {
            0...9 => pad_dsp.adjustParam(&self.pad, id, steps),
            10 => {
                const r = @as(i32, self.root_note) + steps;
                self.root_note = @intCast(std.math.clamp(r, 0, 127));
            },
            11 => if (steps != 0) {
                self.mono = !self.mono;
            },
            else => {},
        }
    }

    /// Absolute-value counterpart to `adjustParam`, same id space and clamp
    /// ranges - for undo's capture/restore (`paramValue` is the read half),
    /// mirroring PolySynth's own pair. Toggles (reverse 9, mono 11): >= 0.5
    /// is on. Runs on the audio thread via the `set_param_abs` event.
    pub fn setParamAbsolute(self: *Sampler, id: u8, value: f32) void {
        switch (id) {
            0...9 => pad_dsp.setParamAbsolute(&self.pad, id, value),
            10 => {
                if (!(value > 0.0)) { // also catches NaN
                    self.root_note = 0;
                } else if (value >= 127.0) {
                    self.root_note = 127;
                } else {
                    self.root_note = @intFromFloat(@round(value));
                }
            },
            11 => self.mono = value >= 0.5,
            else => {},
        }
    }

    /// Current value of param `id`, same unit/encoding `setParamAbsolute`
    /// accepts (toggles as 0/1) - the read half of undo's capture/restore
    /// pair. A control-thread read of live fields, same race-tolerant
    /// convention the sampler editor's own row rendering already uses.
    pub fn paramValue(self: *const Sampler, id: u8) ?f32 {
        return switch (id) {
            0...9 => pad_dsp.paramValue(&self.pad, id),
            10 => @floatFromInt(self.root_note),
            11 => if (self.mono) 1.0 else 0.0,
            else => null,
        };
    }

    /// One entry per continuous `setParamAbsolute`-handled id - same shape
    /// and purpose as PolySynth's own table (`dsp.AutomatableParam`), for the
    /// automation editor's param picker/curve labels/h-l nudge step. Toggles
    /// (reverse=9, mono=11) and root_note=10 are deliberately excluded, same
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
        // zig fmt: on
    };

    pub fn findAutomatableParam(id: u8) ?*const dsp.AutomatableParam {
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
        self.resetAll();
    }

    /// Guess the root note from the currently loaded clip via YIN pitch
    /// detection (see `dsp/pitch.zig`) and, if confident, set `root_note` to
    /// it. Returns the detection result so callers (the `:load-sample`
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
        // Mono mode: a new note always cuts every still-ringing voice first,
        // so long one-shots (e.g. a bass note) never overlap themselves.
        if (self.mono) self.resetAll();

        // Reuse a free voice, else steal the oldest active one.
        var slot: usize = 0;
        var oldest_age: u64 = std.math.maxInt(u64);
        for (&self.voices, 0..) |*nv, i| {
            // zig fmt: off
            if (!nv.active) { slot = i; break; }
            if (nv.age < oldest_age) { oldest_age = nv.age; slot = i; }
            // zig fmt: on
        }
        self.voices[slot] = .{
            .active = true,
            .note = note,
            .semis = @as(f32, @floatFromInt(@as(i16, note) - @as(i16, self.root_note))),
            .age = self.next_age,
            .v = .{ .active = true, .played = 0, .block_start = block_start, .vel = vel },
        };
        self.next_age +%= 1;
    }

    pub fn processBlock(self: *Sampler, buf: []Sample) void {
        const channels = 2;
        const frames: u32 = @intCast(buf.len / channels);
        const sr: f64 = @floatFromInt(self.sample_rate);

        while (!self.pad_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.pad_lock.unlock();

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
            .note_on   => |e| self.trigger(e.note, e.velocity, 0),
            // e.id is u16 (wide enough for DrumMachine's pad-encoded ids);
            // truncate rather than @intCast, same reasoning as PolySynth's
            // identical arm.
            .set_param => |e| self.adjustParam(@truncate(e.id), e.steps),
            .set_param_abs => |e| self.setParamAbsolute(@truncate(e.id), e.value),
            .note_off, .cc, .pitch_bend, .set_sidechain_buf, .capture_pad => {},
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
    s.adjustParam(11, 1);
    try std.testing.expect(s.mono);
    s.adjustParam(11, -1);
    try std.testing.expect(!s.mono);
    s.adjustParam(11, 0); // steps=0 is a no-op, mirroring the reverse toggle
    try std.testing.expect(!s.mono);
}

test "adjustParam edits clip params and root note" {
    var s = try Sampler.init(std.testing.allocator, 48_000);
    defer s.deinit();
    s.adjustParam(2, 5); // pitch +5 semis
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), s.pad.pitch_semitones, 1e-4);
    s.adjustParam(10, -12); // root down an octave
    try std.testing.expectEqual(@as(u7, 48), s.root_note);
    s.adjustParam(9, 1); // reverse toggle
    try std.testing.expect(s.pad.reverse);
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

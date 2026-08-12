//! Step-sequenced multisampler - the drum machine instrument.
//!
//! Up to 64 pads (lazily allocated), each a full embedded `dsp.Sampler`
//! (see sampler.zig): its own clip, start/end trim, pitch, amplitude ADSR,
//! gain, pan, and reverse toggle. DrumMachine itself only adds the step
//! sequencer on top - sample loading, param edits, and voice rendering are
//! delegated straight to each pad's Sampler, so there is exactly one place
//! that owns that logic (shared with the standalone melodic Sampler track).
//! A step trigger is `pad.resetAll()` + `pad.trigger(...)`: the reset forces
//! single-voice "choke" behaviour (a retrigger cuts the previous hit, the
//! classic drum-machine convention) even though Sampler itself is polyphonic.
//!
//! Each pad step is stored as a compact MIDI note (`midi`, a per-pad,
//! heap-owned slice sized to `step_count`) - the sole source of truth for
//! both the audio thread's firing loop and the UI. There used to also be a
//! `u64` bitmask (`pattern`) and a parallel `vel` array; that bitmask is
//! exactly why steps were once hard-capped at 64 (a single word's bit
//! width, not a chosen limit). Pattern positions use fixed 32 ticks per beat;
//! editor grid division only changes navigation and rendering stride. The
//! sequencer fires on tick boundaries derived
//! from the transport, using a monotonic step counter to avoid the
//! double-fire and float-truncation bugs that arise from recomputing the
//! boundary position every block; MPC-style swing (50–75%) delays each
//! off-beat 16th within its 8th-note pair.
//!
//! Per-pad params are plain scalar fields read by the audio thread and
//! nudged on the audio thread (via the `set_param` device event, with the
//! pad index in the id's high bits, see `paramId`), the same race-free
//! path the synth editor uses. The UI reads them for display without
//! locking, matching the synth editor's convention.
//!
//! Pads can also be assigned to a choke group (0 = none, 1..max_choke_groups):
//! triggering a pad silences every other pad sharing its group, the classic
//! closed/open-hihat behaviour. `choke_group` is a plain per-pad array (same
//! race-tolerant convention as `step_count` - control thread writes, audio
//! thread reads, no atomics) nudged only by the rare `cycleChokeGroup` key.
//!
//! `midi`/`Variant.midi`/`SongClip.midi` are heap-owned per-pad slices
//! rather than inline `[max_pads][max_steps]` arrays: max_steps is now
//! u16's own natural ceiling (65535), and an inline array at that size
//! would blow up `@sizeOf(DrumMachine)` across the 8-slot variant bank into
//! multi-MB territory - exactly the failure mode already hit once before
//! (see the `song_clips` field's doc comment) where `init`/`dupe` returning
//! large structs by value segfaulted the test suite. Resizes and variant
//! switches take `pad_lock` (already
//! used for `song_clips`) around the swap so the audio thread never
//! observes a torn slice header; per-cell writes (toggleStep, setStepVel)
//! stay lock-free, same tolerated convention as `choke_group`.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const Transport = @import("../transport.zig").Transport;
const pad_mod = @import("pad.zig");
const drum_kit = @import("drum_kit.zig");
const Sampler = @import("sampler.zig").Sampler;
const Note = @import("pattern.zig").Note;
const step_grid_ops = @import("step_grid_ops.zig");

const Sample = types.Sample;

pub const DrumMachine = struct {
    pub const max_pads: u8 = 64;
    /// Step-grid capacity: the natural ceiling of the u16 step index/count
    /// itself, not a hand-picked "you must fit under this" wall. u8 (255)
    /// was the first candidate but only spans ~2 bars at the finest 1/128
    /// grid (32 steps/beat) - too short to call "not a limit". u16 spans
    /// ~512 bars at that same zoom, which is.
    pub const max_steps: u16 = std.math.maxInt(u16);
    /// Canonical pattern resolution. Editor grids only choose cursor stride.
    pub const ticks_per_beat: u8 = 32;
    /// Max pattern variants (A..H) one machine can hold.
    pub const max_variants: u8 = 8;
    /// Max choke groups a pad can belong to (0 = no group, ungated).
    pub const max_choke_groups: u8 = 4;
    /// Max clips one lane can hold for song-mode playback (see `song_clips`).
    pub const max_song_clips: u16 = 256;

    /// Swing bounds, MPC-style percent: 50 = straight, 66.7 = triplet feel,
    /// 75 = the hardest shuffle. Position of the off-beat 16th within its
    /// 8th-note pair.
    pub const swing_min: f32 = 50.0;
    pub const swing_max: f32 = 75.0;

    /// Full-velocity value (127, MIDI-style max) - a fresh/toggled-on step's
    /// default.
    pub const vel_full: u8 = 127;

    /// Compact canonical note for the drum grid. Timing uses fixed 1/128-note
    /// ticks, so off-grid positions remain exact across editor grid changes.
    /// Elektron's trig conditions, folded into one slot instead of the
    /// Digitakt II's three: the hardware has an encoder to scroll a long
    /// list, a keyboard has one key to cycle it, so the list stays short and
    /// covers the ratios people actually reach for. `always` is the default
    /// and costs one compare on the audio thread.
    ///
    /// `aNbM` is Elektron's A:B - true on the Nth of every M passes through
    /// the row. `first` fires only on the very first pass (a one-shot intro
    /// hit); `fill` and `not_fill` gate on `fill_on`, the performance switch
    /// that swaps a pattern into its fill without editing it.
    pub const Cond = enum(u8) {
        always,
        first,
        not_first,
        fill,
        not_fill,
        a1b2,
        a2b2,
        a1b3,
        a1b4,
        a2b4,
        a3b4,
        a4b4,
        a1b8,

        /// The A:B pair, or null for the non-ratio conditions.
        pub fn ratio(self: Cond) ?struct { a: u8, b: u8 } {
            return switch (self) {
                .a1b2 => .{ .a = 1, .b = 2 },
                .a2b2 => .{ .a = 2, .b = 2 },
                .a1b3 => .{ .a = 1, .b = 3 },
                .a1b4 => .{ .a = 1, .b = 4 },
                .a2b4 => .{ .a = 2, .b = 4 },
                .a3b4 => .{ .a = 3, .b = 4 },
                .a4b4 => .{ .a = 4, .b = 4 },
                .a1b8 => .{ .a = 1, .b = 8 },
                else => null,
            };
        }

        /// Short label for the status line and both grids.
        pub fn label(self: Cond) []const u8 {
            return switch (self) {
                .always => "--",
                .first => "1ST",
                .not_first => "!1ST",
                .fill => "FILL",
                .not_fill => "!FILL",
                .a1b2 => "1:2",
                .a2b2 => "2:2",
                .a1b3 => "1:3",
                .a1b4 => "1:4",
                .a2b4 => "2:4",
                .a3b4 => "3:4",
                .a4b4 => "4:4",
                .a1b8 => "1:8",
            };
        }

        /// Does this condition let the step through on `pass` (0-based count
        /// of completed loops through the row), with the fill switch in
        /// `fill_on`?
        pub fn holds(self: Cond, pass: u64, fill_on: bool) bool {
            if (self.ratio()) |r| return pass % r.b == r.a - 1;
            return switch (self) {
                .always => true,
                .first => pass == 0,
                .not_first => pass != 0,
                .fill => fill_on,
                .not_fill => !fill_on,
                else => unreachable,
            };
        }
    };

    /// The tail of an in-flight roll: the hits that didn't fit in the block
    /// that started it. Positions are absolute transport frames, so a roll
    /// stays aligned to the grid across block boundaries.
    pub const Roll = struct {
        remaining: u8,
        next_pos: f64,
        interval: f64,
        vel: f32,
        tune: i8,
        /// How long each of this roll's hits holds before a gated pad releases
        /// it, in frames, or -1 for "play out" - see `pad.Voice.hold_frames`.
        /// Only the Slicer fills this in; drum pads are one-shots.
        hold: f64 = -1.0,
    };

    pub const MidiNote = struct {
        pitch: u7,
        step: u16,
        duration_steps: u16 = 1,
        velocity: u7 = vel_full,
        /// Chance this step fires at all, in percent (100 = always). The roll
        /// is a hash of the absolute step and the pad, not a running RNG, so
        /// the audio thread stays allocation- and state-free and the same
        /// playthrough sounds the same twice.
        prob: u8 = 100,
        /// Conditional trig, ANDed with `prob` - both have to pass.
        cond: Cond = .always,
        /// Timing offset as a percent of one step, -50 (half a step early) to
        /// +50 (half a step late). Swing shifts every off-beat by the same
        /// amount; this is the per-hit version - a snare dragged late, a hat
        /// pushed early - and it's what `humanizeVelocity` deliberately
        /// couldn't reach.
        micro: i8 = 0,
        /// Hits packed into this step's own duration: 0 or 1 is the plain
        /// single hit, 2+ is a roll (Elektron's Retrig). The hits are evenly
        /// spaced across the step, so the rate follows the pattern's grid
        /// rather than needing a separate division setting.
        retrig: u8 = 0,
        /// Per-step playback transpose in semitones, on top of the pad's own
        /// `pitch_semitones` - Elektron's pitch parameter-lock, the cheap
        /// slice of p-locks that turns one tom into a fill. `pitch` above is
        /// only the pad tag (see `gridNote`), so tuning needs its own field.
        tune: i8 = 0,

        pub fn toPattern(self: MidiNote, steps_per_beat: u8) Note {
            return .{
                .pitch = self.pitch,
                .start_beat = @as(f64, @floatFromInt(self.step)) / @as(f64, @floatFromInt(steps_per_beat)),
                .duration_beat = @as(f64, @floatFromInt(self.duration_steps)) / @as(f64, @floatFromInt(steps_per_beat)),
                .velocity = velGain(self.velocity),
            };
        }
    };

    /// Gain for a step's 0-127 velocity value (127 = full volume).
    pub fn velGain(level: u8) f32 {
        return @as(f32, @floatFromInt(level)) / @as(f32, @floatFromInt(vel_full));
    }

    pub fn gridNote(pad: u8, step: u16, velocity: u8) MidiNote {
        return .{
            .pitch = @intCast(pad),
            .step = step,
            .velocity = @intCast(@min(velocity, vel_full)),
        };
    }

    /// Allocate `max_pads` fresh per-pad note slices, each `len` long and
    /// null-filled. The building block every resize/dupe path shares.
    pub fn allocMidi(allocator: std.mem.Allocator, len: u16) ![max_pads][]?MidiNote {
        var out: [max_pads][]?MidiNote = undefined;
        var i: usize = 0;
        errdefer for (out[0..i]) |s| allocator.free(s);
        while (i < max_pads) : (i += 1) {
            out[i] = try allocator.alloc(?MidiNote, len);
            @memset(out[i], null);
        }
        return out;
    }

    /// Free every pad's slice. Safe (a no-op) on still-empty (`&.{}`) slots,
    /// e.g. a never-materialized variant bank slot.
    pub fn freeMidi(allocator: std.mem.Allocator, midi: *[max_pads][]?MidiNote) void {
        for (midi) |s| allocator.free(s);
    }

    /// Deep-copy every pad's slice into fresh allocations.
    pub fn dupeMidi(allocator: std.mem.Allocator, src: *const [max_pads][]?MidiNote) ![max_pads][]?MidiNote {
        var out: [max_pads][]?MidiNote = undefined;
        var i: usize = 0;
        errdefer for (out[0..i]) |s| allocator.free(s);
        while (i < max_pads) : (i += 1) {
            out[i] = try allocator.dupe(?MidiNote, src[i]);
        }
        return out;
    }

    /// One pattern variant: a bank slot for the step grid. The active variant
    /// lives in the live `midi`/`step_count` fields; inactive ones rest here
    /// as plain data (control thread only). `midi` is heap-owned - see the
    /// file's top doc comment.
    pub const Variant = struct {
        midi: [max_pads][]?MidiNote = [_][]?MidiNote{&.{}} ** max_pads,
        step_count: u16 = ticks_per_beat * 4,
        /// Canonical musical ticks in one quarter-note beat.
        steps_per_beat: u8 = ticks_per_beat,
    };

    /// A drum clip flattened onto the arrangement's step timeline. No
    /// atomics - the audio thread reads it under `pad_lock`. The clip's own
    /// `step_count`-long pattern repeats to fill `span_steps` (its
    /// whole-bar length on the timeline). `midi` is heap-owned: `setSongClips`
    /// takes ownership of whatever is passed in (build fresh slices per call,
    /// e.g. via `dupeMidi`, and don't reuse or free them yourself afterward).
    pub const SongClip = struct {
        start_step: u32,
        span_steps: u32,
        step_count: u16,
        steps_per_beat: u8 = ticks_per_beat,
        midi: [max_pads][]?MidiNote,
    };
    /// Number of editable params per pad (see `adjustParam`) - `pad.zig`'s
    /// whole shared table. Sampler's own root-note/mono ids past it stay off
    /// the drum grid (a pad has no chromatic root and always chokes itself).
    pub const pad_param_count: u8 = pad_mod.param_count;
    /// Max simultaneous per-pad sidechain-detector capture requests one
    /// block can carry - matches `Engine.max_sidechain_sources`, the real
    /// upper bound (every request this machine could ever receive in one
    /// block originates from that bank). Kept as its own small constant
    /// rather than importing audio/engine.zig just for it (engine.zig
    /// already imports this file - see `Event.capture_pad`'s doc comment).
    pub const max_pad_captures: u8 = 8;

    /// One pad's per-block isolated-capture request - see `Event.
    /// capture_pad`'s doc comment. `buf`'s lifetime is exactly one block:
    /// stashed here by `handleEvent`, consumed and cleared by the very next
    /// `processBlock` call.
    const PadCapture = struct { pad: u8, buf: []Sample };
    /// Id-space stride per pad. `set_param` ids are `pad << 5 | param`, so the
    /// stride is a power of two and pad/param decode with shift + mask. Was
    /// 16 (4-bit param field) until the per-pad LFO's 4 new ids pushed
    /// `pad_dsp.param_count` past 16; widened to 32 (5 bits) rather than
    /// adding a second id mechanism. u16: at max_pads=64, `63 << 5 | param`
    /// is 2016+, still well past what a u8 id could hold (this used to cap
    /// addressable pads at 15) - see dsp/device.zig's Event.set_param doc
    /// comment.
    pub const param_stride: u16 = 32;

    allocator: std.mem.Allocator,
    sample_rate: u32,
    transport: *const Transport,

    /// Up to 64 full Samplers, one per pad - lazily materialized. `null`
    /// means the pad has never had a sample loaded into it: no Sampler
    /// exists, no memory beyond the tag (a materialized Sampler carries a
    /// real audio buffer, ~115KB even for the generated default clip, which
    /// matters multiplied out to 64 pads if every unused slot paid it).
    /// Materializes on `loadPadWav`/`setPadSamples`; every accessor treats
    /// null as "silent, nothing to do" - same "no override" shape
    /// `AutomationCurve`'s null case already uses elsewhere. Each
    /// materialized pad guards its own clip buffer against concurrent reads
    /// (audio thread) and writes (control thread calling loadPadWav/
    /// setPadSamples at runtime) - see Sampler.pad_lock.
    pads: [max_pads]?Sampler,
    /// Guards `midi`/`song_clips`/`song_clip_count`/`song_length_steps`
    /// against concurrent control-thread writes (any structural resize, or
    /// setSongClips) while the audio thread reads them in processBlock.
    pad_lock: std.atomic.Mutex = .unlocked,
    /// Canonical live pattern: one heap-owned, `step_count`-long slice per
    /// pad. Control thread writes (resize under `pad_lock`; per-cell writes
    /// lock-free, matching `choke_group`'s convention), audio thread reads
    /// directly in `processBlock`. Always mirrors the active variant; edits
    /// land here and are synced back to `variants[variant]` when switching
    /// away.
    midi: [max_pads][]?MidiNote,
    /// Cached slice length of every row in `midi` - control thread writes,
    /// audio thread reads (plain field, no atomics - same convention as
    /// `choke_group`).
    step_count: u16,
    /// Canonical timing resolution. Always `ticks_per_beat` in live data.
    steps_per_beat: u8 = ticks_per_beat,
    /// Swing percent (see `swing_min`/`swing_max`): where the off-beat 16th
    /// sits within its 8th-note pair. UI writes, audio thread reads.
    swing: std.atomic.Value(f32) = .init(50.0),
    /// Per-pad choke group (0 = none). See `chokeTriggerTuned`.
    choke_group: [max_pads]u8 = [_]u8{0} ** max_pads,
    /// Name of the last factory kit flavour applied, borrowed from
    /// `drum_kit.variants` (static storage, never freed). Empty on a fresh
    /// machine, which is the blank "init" kit in all but name. Persisted so
    /// a project reload can regenerate the audio instead of shipping it -
    /// see `persist.DrumSnap.kit`.
    kit: []const u8 = "",
    /// Per-pad loop length in steps, 0 = follow the pattern (the default and
    /// the only behaviour before this existed). A shorter length makes that
    /// row wrap on its own, so a 7-step hat drifts against a 16-step kick for
    /// 112 steps before the two line up again - Elektron's per-track lengths,
    /// the reason a Digitakt pattern doesn't sound like 16 steps on repeat.
    ///
    /// Machine-level, not per-variant, and clamped at use time rather than
    /// on write: the row's storage is only ever `step_count` long, so a
    /// length past the pattern silently follows the pattern instead. Same
    /// convention `choke_group` and `swing` already use, which is also why
    /// song mode picks it up for free (see `fireSongStep`).
    pad_len: [max_pads]u16 = [_]u16{0} ** max_pads,
    /// Performance switch the `fill`/`not_fill` trig conditions read: flip it
    /// and every step conditioned on it swaps in or out, no editing. UI
    /// writes, audio thread reads.
    fill_on: std.atomic.Value(bool) = .init(false),
    /// Hits the sequencer has decided on but not yet emitted, one slot per
    /// pad (audio thread only). Everything the sequencer fires goes through
    /// here rather than being triggered at the step boundary, because a hit's
    /// real time is no longer its step's: a roll's tail lands blocks later,
    /// and a `micro`-shifted hit can land before its own step boundary, which
    /// a boundary-ordered scan could never emit at the right frame.
    ///
    /// One slot per pad: a fresh trigger on that pad chokes whatever was
    /// ringing anyway, so a second overlapping schedule could never be heard.
    /// Live pad hits (`triggerPad`) skip this and fire immediately.
    rolls: [max_pads]?Roll = [_]?Roll{null} ** max_pads,

    // ── Pattern variants (control thread only) ──────────────────────────────
    /// Bank slots. Slot `variant` is stale while active - read it through
    /// `variantData`, which pulls the live state instead. Only slots
    /// `0..variant_count` ever hold a real allocation; every mutator that
    /// touches this array (dupe, deinit, add/removeVariant) must iterate
    /// that range, not `0..max_variants` - slots past `variant_count` may
    /// alias a moved-out pointer from a prior `removeVariant` shift and are
    /// never independently owned (see `removeVariant`'s doc comment).
    variants: [max_variants]Variant = [_]Variant{.{}} ** max_variants,
    variant_count: u8 = 1,
    /// Index of the active variant (the one in the live `midi`).
    variant: u8 = 0,

    // ── Song-mode playback (control thread writes, audio thread reads under
    //    pad_lock) ──────────────────────────────────────────────────────────
    /// When true, processBlock fires from `song_clips` under the playhead
    /// instead of the live pattern. Set via Session.setSongMode.
    song_mode: bool = false,
    /// The lane's clips placed on the arrangement's step timeline. Heap
    /// slice of length `max_song_clips` (owned, freed in deinit): inline it
    /// would be ~1.2MB, pushing @sizeOf(DrumMachine) past what by-value
    /// construction (init/dupe through Session.setInstrument) can stack.
    /// Only `song_clips[0..song_clip_count]` hold real `midi` allocations
    /// (see `setSongClips`); slots past that are uninitialized until used.
    song_clips: []SongClip,
    song_clip_count: u16 = 0,
    /// Whole-arrangement length in steps; the song loops at this boundary.
    song_length_steps: u32 = 0,
    song_steps_per_beat: u8 = ticks_per_beat,

    // Audio-thread-only state:
    /// Monotonic counter of steps that have fired. Resynced on seek.
    next_step_k: u64,

    /// Current step index, published by the audio thread for UI display.
    current_step: std.atomic.Value(u16),
    /// This block's registered pad-capture requests (see `PadCapture`) -
    /// audio-thread-only, filled by `handleEvent` right before `process()`
    /// runs and cleared at the end of the same `processBlock` call.
    pad_captures: [max_pad_captures]?PadCapture = [_]?PadCapture{null} ** max_pad_captures,

    pub fn init(
        allocator: std.mem.Allocator,
        sample_rate: u32,
        transport: *const Transport,
    ) !DrumMachine {
        const song_clips = try allocator.alloc(SongClip, max_song_clips);
        errdefer allocator.free(song_clips);
        const default_step_count: u16 = @as(u16, ticks_per_beat) * 8; // default 2 bars
        var midi = try allocMidi(allocator, default_step_count);
        errdefer freeMidi(allocator, &midi);

        var self: DrumMachine = .{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .transport = transport,
            .pads = undefined,
            .song_clips = song_clips,
            .midi = midi,
            .step_count = default_step_count,

            .next_step_k = 0,
            .current_step = .init(0),
        };
        // Every pad starts null - the "init" kit's blank slate (see
        // dsp/drum_kit.zig's `variants`). A fresh machine loads no audio at
        // all; `:drum-kit default` (or any other flavour) fills the 16 kit
        // pads on demand, generating them procedurally.
        for (&self.pads) |*p| p.* = null; // lazily materialized - see the field's doc comment

        return self;
    }

    pub fn deinit(self: *DrumMachine) void {
        for (&self.pads) |*p| if (p.*) |*s| s.deinit();
        for (self.song_clips[0..self.song_clip_count]) |*clip| freeMidi(self.allocator, &clip.midi);
        self.allocator.free(self.song_clips);
        freeMidi(self.allocator, &self.midi);
        for (self.variants[0..self.variant_count]) |*v| freeMidi(self.allocator, &v.midi);
    }

    /// Deep copy for track duplication: starts from a fresh `init` (a blank
    /// machine) so every buffer is uniquely allocated, then
    /// overwrites each pad with a dupe of this machine's actual clip audio
    /// (or leaves it null if the source pad was never loaded) and copies the
    /// pattern bank, step count, and swing. Song-mode state isn't carried -
    /// the caller rebuilds it from the arrangement if needed.
    pub fn dupe(self: *const DrumMachine) !DrumMachine {
        var out = try DrumMachine.init(self.allocator, self.sample_rate, self.transport);
        errdefer out.deinit();

        for (&out.pads, 0..) |*dst, i| {
            if (dst.*) |*d| d.deinit();
            dst.* = if (self.pads[i]) |*src| try src.dupe() else null;
        }
        const midi = try dupeMidi(self.allocator, &self.midi);
        freeMidi(out.allocator, &out.midi);
        out.midi = midi;
        out.step_count = self.step_count;
        out.steps_per_beat = self.steps_per_beat;
        out.swing.store(self.swing.load(.monotonic), .monotonic);
        out.choke_group = self.choke_group;
        out.pad_len = self.pad_len;
        out.kit = self.kit; // static storage - see the field's doc comment

        // Set the target count first (not after the loop) so a mid-loop
        // allocation failure leaves `out.deinit()` freeing exactly the
        // intended range - some slots already real dupes, the rest still
        // their fresh-`init` empty default, both safe to free.
        out.variant_count = self.variant_count;
        for (self.variants[0..self.variant_count], 0..) |*src_slot, i| {
            out.variants[i] = .{
                .midi = try dupeMidi(self.allocator, &src_slot.midi),
                .step_count = src_slot.step_count,
                .steps_per_beat = src_slot.steps_per_beat,
            };
        }
        out.variant = self.variant;

        return out;
    }

    pub const device = dsp.deviceOf(@This());

    // -----------------------------------------------------------------------
    // Pattern editing (UI thread)

    /// Resize the live pattern to `n` steps, clamped to `[1, max_steps]`.
    /// Existing notes up to `min(old, new)` survive; a shrink then regrow
    /// does not resurrect anything past the new count (matches the old
    /// bitmask-era hygiene: nothing stray can resurface invisibly).
    /// Silently leaves the pattern unchanged on allocation failure - a
    /// user-triggered, rare-OOM control-thread action, not a hot path.
    pub fn setStepCount(self: *DrumMachine, n: u16) void {
        const new_count = std.math.clamp(n, 1, max_steps);
        if (new_count == self.step_count) return;
        var next = allocMidi(self.allocator, new_count) catch return;
        const keep = @min(self.step_count, new_count);
        for (0..max_pads) |pad| @memcpy(next[pad][0..keep], self.midi[pad][0..keep]);

        while (!self.pad_lock.tryLock()) std.atomic.spinLoopHint();
        freeMidi(self.allocator, &self.midi);
        self.midi = next;
        self.step_count = new_count;
        self.pad_lock.unlock();
    }

    pub fn copyPadMidi(self: *const DrumMachine, pad: u8, out: []Note) u16 {
        if (pad >= max_pads) return 0;
        var count: u16 = 0;
        for (self.midi[pad]) |maybe_note| {
            const note = maybe_note orelse continue;
            if (count >= out.len) break;
            out[count] = note.toPattern(self.steps_per_beat);
            count += 1;
        }
        return count;
    }

    /// Nudge swing by `delta` percent, clamped to [swing_min, swing_max].
    /// Control thread; the audio thread picks it up next block.
    pub fn adjustSwing(self: *DrumMachine, delta: f32) void {
        if (!std.math.isFinite(delta)) return;
        const s = std.math.clamp(self.swing.load(.monotonic) + delta, swing_min, swing_max);
        self.swing.store(s, .monotonic);
    }

    /// Step pad `pad`'s choke group forward: none → 1 → 2 → … → max → none.
    /// Control thread; a mixer-style param, not undo-tracked (like swing).
    pub fn cycleChokeGroup(self: *DrumMachine, pad: u8) void {
        if (pad >= max_pads) return;
        self.choke_group[pad] = (self.choke_group[pad] + 1) % (max_choke_groups + 1);
    }

    // -----------------------------------------------------------------------
    // Pattern variants (control thread)

    /// Sync the live pattern back into its bank slot. Silently leaves the
    /// slot's stale data in place on allocation failure (rare OOM,
    /// non-fatal - same tolerance as `setStepCount`).
    fn storeActiveVariant(self: *DrumMachine) void {
        const slot = &self.variants[self.variant];
        const fresh = dupeMidi(self.allocator, &self.midi) catch return;
        freeMidi(self.allocator, &slot.midi);
        slot.midi = fresh;
        slot.step_count = self.step_count;
        slot.steps_per_beat = self.steps_per_beat;
    }

    /// Replace the live pattern with `slot`'s data (control thread). Used to
    /// activate a bank variant and to paste a yanked pattern. Silently
    /// leaves the live pattern unchanged on allocation failure.
    pub fn applyVariant(self: *DrumMachine, slot: Variant) void {
        const want: u16 = std.math.clamp(slot.step_count, 1, max_steps);
        const fresh = (if (slot.midi[0].len == 0)
            allocMidi(self.allocator, want)
        else
            dupeMidi(self.allocator, &slot.midi)) catch return;
        while (!self.pad_lock.tryLock()) std.atomic.spinLoopHint();
        freeMidi(self.allocator, &self.midi);
        self.midi = fresh;
        self.step_count = @intCast(fresh[0].len);
        self.steps_per_beat = std.math.clamp(slot.steps_per_beat, 1, 32);
        self.pad_lock.unlock();
    }

    /// Load bank slot `v` into the live pattern.
    fn loadVariantLive(self: *DrumMachine, v: u8) void {
        self.applyVariant(self.variants[v]);
    }

    /// Switch the active variant to `v`, saving the live pattern first.
    pub fn selectVariant(self: *DrumMachine, v: u8) void {
        if (v >= self.variant_count or v == self.variant) return;
        self.storeActiveVariant();
        self.variant = v;
        self.loadVariantLive(v);
    }

    /// Step the active variant by `delta`, wrapping within the bank.
    pub fn cycleVariant(self: *DrumMachine, delta: i32) void {
        const n: i32 = self.variant_count;
        if (n <= 1) return;
        self.selectVariant(@intCast(@mod(@as(i32, self.variant) + delta, n)));
    }

    /// Duplicate the active variant into a new slot and switch to it - the
    /// live pattern already matches the copy. False when the bank is full
    /// or the copy's allocation fails (rare OOM).
    pub fn addVariant(self: *DrumMachine) bool {
        if (self.variant_count >= max_variants) return false;
        self.storeActiveVariant();
        const fresh = dupeMidi(self.allocator, &self.variants[self.variant].midi) catch return false;
        self.variants[self.variant_count] = .{
            .midi = fresh,
            .step_count = self.variants[self.variant].step_count,
            .steps_per_beat = self.variants[self.variant].steps_per_beat,
        };
        self.variant = self.variant_count;
        self.variant_count += 1;
        return true;
    }

    /// Remove the active variant, shifting later slots down. The slot that
    /// takes its index (or the new last) becomes active. False when it's the
    /// only one left. Frees the removed slot's own allocation first, then
    /// shifts ownership of every later slot down by one - the vacated slot
    /// at the old `variant_count` position is left holding a stale aliased
    /// copy of what's now `variants[variant_count-2]`'s pointers, never
    /// touched again since every iteration elsewhere is bounded to
    /// `0..variant_count`.
    pub fn removeVariant(self: *DrumMachine) bool {
        if (self.variant_count <= 1) return false;
        freeMidi(self.allocator, &self.variants[self.variant].midi);
        var i = self.variant;
        while (i + 1 < self.variant_count) : (i += 1) self.variants[i] = self.variants[i + 1];
        self.variant_count -= 1;
        if (self.variant >= self.variant_count) self.variant = self.variant_count - 1;
        self.loadVariantLive(self.variant);
        return true;
    }

    /// Variant `v`'s pattern data. The active one is read from the live
    /// state (its bank slot is stale until the next switch). The returned
    /// `Variant.midi` slices are borrowed (alias either the live pattern or
    /// the bank slot) - the caller must not free them or hold the result
    /// past a point where the source might be resized/freed.
    pub fn variantData(self: *const DrumMachine, v: u8) Variant {
        if (v == self.variant) {
            return .{ .midi = self.midi, .step_count = self.step_count, .steps_per_beat = self.steps_per_beat };
        }
        return self.variants[@min(v, max_variants - 1)];
    }

    /// Display letter for variant `v`: A, B, C, …
    pub fn variantLetter(v: u8) u8 {
        return 'A' + @as(u8, @min(v, max_variants - 1));
    }

    /// Replace the song-mode clip timeline (control thread). Takes ownership
    /// of every clip's `midi` slices - build them fresh per call (e.g. via
    /// `dupeMidi`) and don't free or reuse them afterward. Taken under
    /// `pad_lock` so the audio thread never reads a half-written array.
    pub fn setSongClips(self: *DrumMachine, clips: []const SongClip, length_steps: u32, steps_per_beat: u8) void {
        while (!self.pad_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.pad_lock.unlock();
        for (self.song_clips[0..self.song_clip_count]) |*old| freeMidi(self.allocator, &old.midi);
        const count = @min(clips.len, @as(usize, max_song_clips));
        for (clips[0..count], self.song_clips[0..count]) |src, *dst| dst.* = src;
        for (clips[count..]) |src| {
            var dropped = src;
            freeMidi(self.allocator, &dropped.midi);
        }
        self.song_clip_count = @intCast(count);
        self.song_length_steps = length_steps;
        self.song_steps_per_beat = std.math.clamp(steps_per_beat, 1, 32);
    }

    pub fn toggleStep(self: *DrumMachine, pad: u8, step: u16) void {
        step_grid_ops.toggleStep(&self.midi, self.step_count, pad, step);
    }

    // Step editing is `step_grid_ops.zig`'s, shared with the Slicer's identical
    // grid; only the pad vocabulary is ours. See that file for the bodies.
    pub fn stepActive(self: *const DrumMachine, pad: u8, step: u16) bool {
        return step_grid_ops.stepActive(&self.midi, self.step_count, pad, step);
    }

    /// One step's velocity, 0-127 (127 = full, see velGain). 127 for a step
    /// with no note, matching a fresh/toggled-on step's default.
    pub fn stepVel(self: *const DrumMachine, pad: u8, step: u16) u8 {
        return step_grid_ops.stepVel(&self.midi, self.step_count, pad, step);
    }

    pub fn setStepVel(self: *DrumMachine, pad: u8, step: u16, level: u8) void {
        step_grid_ops.setStepVel(&self.midi, self.step_count, pad, step, level);
    }

    /// Cycle through the named preset bands (127→95→63→31→127) - a quick
    /// single-key gesture; `nudgeStepVel` covers the full 1-127 range.
    pub fn cycleStepVel(self: *DrumMachine, pad: u8, step: u16) void {
        step_grid_ops.cycleStepVel(&self.midi, self.step_count, pad, step);
    }

    /// Nudge one step's velocity by `delta`, clamped to 1..127 - 0 would be
    /// silent; use x/X to remove a step instead of zeroing its velocity.
    pub fn nudgeStepVel(self: *DrumMachine, pad: u8, step: u16, delta: i32) void {
        step_grid_ops.nudgeStepVel(&self.midi, self.step_count, pad, step, delta);
    }

    pub const trigFires = step_grid_ops.trigFires;

    /// Steps pad `p` actually loops over inside a `pattern_len`-long pattern:
    /// its own `pad_len` when that's set and fits, else the whole pattern.
    /// Audio thread reads this every step boundary, so it stays branch-cheap
    /// and never touches storage it doesn't have.
    pub fn padSteps(self: *const DrumMachine, p: u8, pattern_len: u16) u16 {
        return step_grid_ops.laneSteps(&self.pad_len, p, pattern_len);
    }

    /// Set pad `p`'s own loop length; 0 (or anything past the pattern) goes
    /// back to following the pattern.
    pub fn setPadLen(self: *DrumMachine, p: u8, len: u16) void {
        step_grid_ops.setLaneLen(&self.pad_len, self.step_count, p, len);
    }

    /// Nudge pad `p`'s loop length, treating "follows the pattern" as the
    /// full length so stepping down from it lands one below rather than
    /// jumping to 1.
    pub fn nudgePadLen(self: *DrumMachine, p: u8, delta: i32) void {
        step_grid_ops.nudgeLaneLen(&self.pad_len, self.step_count, p, delta);
    }

    /// Fire chance of the step in percent; 100 on an empty step.
    pub fn stepProb(self: *const DrumMachine, pad: u8, step: u16) u8 {
        return step_grid_ops.stepProb(&self.midi, self.step_count, pad, step);
    }

    /// Set the chance outright, clamped to 0-100. The keyboard only walks
    /// the presets; scripts (and anything else wanting an exact value) need
    /// the direct setter, same split `stepVel` already has.
    pub fn setStepProb(self: *DrumMachine, pad: u8, step: u16, percent: i32) void {
        step_grid_ops.setStepProb(&self.midi, self.step_count, pad, step, percent);
    }

    pub fn cycleStepProb(self: *DrumMachine, pad: u8, step: u16) void {
        step_grid_ops.cycleStepProb(&self.midi, self.step_count, pad, step);
    }

    /// Timing offset of the step as a percent of one step; 0 on an empty one.
    pub fn stepMicro(self: *const DrumMachine, pad: u8, step: u16) i8 {
        return step_grid_ops.stepMicro(&self.midi, self.step_count, pad, step);
    }

    /// Half a step either way. Past that a hit would cross its neighbour's
    /// boundary, which is a different step, not a feel.
    pub fn setStepMicro(self: *DrumMachine, pad: u8, step: u16, pct: i32) void {
        step_grid_ops.setStepMicro(&self.midi, self.step_count, pad, step, pct);
    }

    pub fn nudgeStepMicro(self: *DrumMachine, pad: u8, step: u16, delta: i32) void {
        step_grid_ops.nudgeStepMicro(&self.midi, self.step_count, pad, step, delta);
    }

    /// Hits packed into the step; 0 (a plain single hit) on an empty step.
    pub fn stepRetrig(self: *const DrumMachine, pad: u8, step: u16) u8 {
        return step_grid_ops.stepRetrig(&self.midi, self.step_count, pad, step);
    }

    /// Set the roll size outright, clamped to 0-8 (the widest preset).
    /// Direct-setter twin of `cycleStepRetrig`.
    pub fn setStepRetrig(self: *DrumMachine, pad: u8, step: u16, hits: i32) void {
        step_grid_ops.setStepRetrig(&self.midi, self.step_count, pad, step, hits);
    }

    pub fn cycleStepRetrig(self: *DrumMachine, pad: u8, step: u16) void {
        step_grid_ops.cycleStepRetrig(&self.midi, self.step_count, pad, step);
    }

    /// Trig condition on the step; `always` on an empty step.
    pub fn stepCond(self: *const DrumMachine, pad: u8, step: u16) Cond {
        return step_grid_ops.stepCond(&self.midi, self.step_count, pad, step);
    }

    /// Set the condition outright. Direct-setter twin of `cycleStepCond`.
    pub fn setStepCond(self: *DrumMachine, pad: u8, step: u16, cond: Cond) void {
        step_grid_ops.setStepCond(&self.midi, self.step_count, pad, step, cond);
    }

    /// Walk the condition list by `delta` (wrapping), the keyboard stand-in
    /// for the hardware's encoder.
    pub fn cycleStepCond(self: *DrumMachine, pad: u8, step: u16, delta: i32) void {
        step_grid_ops.cycleStepCond(&self.midi, self.step_count, pad, step, delta);
    }

    /// Flip the fill switch every `fill`/`not_fill` step reads. Returns the
    /// new state so the caller can report it.
    pub fn toggleFill(self: *DrumMachine) bool {
        const next = !self.fill_on.load(.monotonic);
        self.fill_on.store(next, .monotonic);
        return next;
    }

    /// Per-step transpose in semitones, 0 on an empty step (nothing to tune).
    pub fn stepTune(self: *const DrumMachine, pad: u8, step: u16) i8 {
        return step_grid_ops.stepTune(&self.midi, self.step_count, pad, step);
    }

    /// Same ±24 semitone range a pad's own pitch param clamps to, so a hit
    /// can't be tuned somewhere the pad itself could never reach.
    pub fn setStepTune(self: *DrumMachine, pad: u8, step: u16, semis: i32) void {
        step_grid_ops.setStepTune(&self.midi, self.step_count, pad, step, semis);
    }

    pub fn nudgeStepTune(self: *DrumMachine, pad: u8, step: u16, delta: i32) void {
        step_grid_ops.nudgeStepTune(&self.midi, self.step_count, pad, step, delta);
    }

    /// Wipe one pad's row: no steps.
    pub fn clearPad(self: *DrumMachine, pad: u8) void {
        if (pad >= max_pads) return;
        @memset(self.midi[pad], null);
    }

    /// Fill one pad's row with full-velocity steps across the active length.
    pub fn fillPad(self: *DrumMachine, pad: u8) void {
        if (pad >= max_pads) return;
        for (self.midi[pad], 0..) |*note, step| note.* = gridNote(pad, @intCast(step), vel_full);
    }

    /// Wipe every pad's row - `:clear`'s whole-kit counterpart to
    /// `clearPad`. Returns the total hit count removed, for the status line.
    pub fn clearKit(self: *DrumMachine) u32 {
        var n: u32 = 0;
        for (self.midi) |row| {
            for (row) |slot| {
                if (slot != null) n += 1;
            }
        }
        for (0..max_pads) |pad| self.clearPad(@intCast(pad));
        return n;
    }

    /// Jitter every active hit's velocity across the whole kit by
    /// ±`amount_pct`% (relative, clamped to 1-127), 0-100 - the drum-machine
    /// counterpart to `PatternPlayer.humanize`'s velocity half. Timing stays
    /// exactly on-grid: a hit has only an integer `step`, no fractional
    /// offset to jitter, so unlike the melodic version this only ever
    /// touches feel via dynamics, not micro-timing.
    pub fn humanizeVelocity(self: *DrumMachine, amount_pct: f64, seed: u64) void {
        if (!std.math.isFinite(amount_pct)) return;
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();
        const frac: f32 = @floatCast(std.math.clamp(amount_pct, 0.0, 100.0) / 100.0);
        for (self.midi) |row| {
            for (row) |*slot| {
                if (slot.*) |*note| {
                    const dv = (rand.float(f32) * 2.0 - 1.0) * frac * @as(f32, vel_full);
                    const v: f32 = @as(f32, @floatFromInt(note.velocity)) + dv;
                    note.velocity = @intFromFloat(std.math.clamp(@round(v), 1.0, vel_full));
                }
            }
        }
    }

    /// Scale every hit's velocity across the kit so the loudest lands at
    /// `vel_full`, keeping the pattern's internal dynamics - the drum
    /// counterpart to `PatternPlayer.normalizeVelocity`. No-op when the kit
    /// already peaks. Returns the count touched.
    pub fn normalizeVelocity(self: *DrumMachine) u32 {
        var peak: u8 = 0;
        for (self.midi) |row| {
            for (row) |slot| {
                if (slot) |note| peak = @max(peak, @as(u8, note.velocity));
            }
        }
        if (peak == 0 or peak == vel_full) return 0;
        const gain = @as(f32, @floatFromInt(vel_full)) / @as(f32, @floatFromInt(peak));
        var touched: u32 = 0;
        for (self.midi) |row| {
            for (row) |*slot| {
                if (slot.*) |*note| {
                    const v = @as(f32, @floatFromInt(note.velocity)) * gain;
                    note.velocity = @intFromFloat(std.math.clamp(@round(v), 1.0, @as(f32, @floatFromInt(vel_full))));
                    touched += 1;
                }
            }
        }
        return touched;
    }

    /// Replace one pad's row with a Euclidean rhythm: `pulses` full-velocity
    /// hits spread as evenly as possible across the pattern (the Bresenham
    /// formulation of Bjorklund's algorithm - onset wherever the running
    /// remainder `i*pulses mod steps` wraps), shifted `rotation` steps later
    /// so the first hit lands on step `rotation`. 0 pulses clears the row;
    /// pulses beyond the step count saturate to every-step.
    pub fn euclidPad(self: *DrumMachine, pad: u8, pulses: u16, rotation: i32) void {
        if (pad >= max_pads or self.step_count == 0) return;
        const steps: u64 = self.step_count;
        const k: u64 = @min(pulses, self.step_count);
        for (self.midi[pad], 0..) |*note, i| {
            const idx: u64 = @intCast(@mod(@as(i64, @intCast(i)) - rotation, @as(i64, @intCast(steps))));
            const on = k > 0 and (idx * k) % steps < k;
            note.* = if (on) gridNote(pad, @intCast(i), vel_full) else null;
        }
    }

    /// Linearly ramp one pad's hit velocities: the row's first hit gets
    /// `v0`, the last `v1`, hits between interpolate by step position - a
    /// hi-hat build in one call. A lone hit gets `v1` (the ramp's target).
    /// Values clamp to 1..127; a silent hit is x/X's job, not velocity 0.
    /// Returns the count touched.
    pub fn velocityRampPad(self: *DrumMachine, pad: u8, v0: u8, v1: u8) u16 {
        if (pad >= max_pads) return 0;
        var first: ?u16 = null;
        var last: u16 = 0;
        for (self.midi[pad], 0..) |slot, i| {
            if (slot == null) continue;
            if (first == null) first = @intCast(i);
            last = @intCast(i);
        }
        const lo = first orelse return 0;
        var touched: u16 = 0;
        for (self.midi[pad], 0..) |*slot, i| {
            if (slot.* == null) continue;
            const t: f32 = if (last > lo)
                @as(f32, @floatFromInt(i - lo)) / @as(f32, @floatFromInt(last - lo))
            else
                1.0;
            const v = @as(f32, @floatFromInt(v0)) + (@as(f32, @floatFromInt(v1)) - @as(f32, @floatFromInt(v0))) * t;
            slot.*.?.velocity = @intFromFloat(std.math.clamp(@round(v), 1.0, 127.0));
            touched += 1;
        }
        return touched;
    }

    /// Time-mirror (retrograde) the whole live pattern: every hit's span
    /// [step, step+duration) maps to [N-step-duration, N-step), so 1-step
    /// hits land on the mirrored slot and longer notes end where they used
    /// to begin. Rows rebuild through one scratch row (two notes sharing an
    /// end step would collide mirrored - the later source step wins); a
    /// failed scratch allocation leaves the pattern untouched.
    pub fn reversePattern(self: *DrumMachine) void {
        const n: u32 = self.step_count;
        if (n == 0) return;
        const scratch = self.allocator.alloc(?MidiNote, n) catch return;
        defer self.allocator.free(scratch);
        for (0..max_pads) |pad| {
            @memset(scratch, null);
            for (self.midi[pad]) |slot| {
                const note = slot orelse continue;
                const end = @as(u32, note.step) + @max(1, note.duration_steps);
                const dst: u16 = @intCast(n - @min(end, n));
                scratch[dst] = note;
                scratch[dst].?.step = dst;
            }
            @memcpy(self.midi[pad], scratch);
        }
    }

    /// Rotate one pad's row `delta` steps later in time (negative = earlier),
    /// wrapping at the pattern boundary. Hits keep their velocity, pitch and
    /// duration; only their grid position moves.
    pub fn rotatePad(self: *DrumMachine, pad: u8, delta: i32) void {
        if (pad >= max_pads or self.midi[pad].len == 0) return;
        const len: i64 = @intCast(self.midi[pad].len);
        // std.mem.rotate rotates left; right-by-delta == left-by-(-delta mod len)
        std.mem.rotate(?MidiNote, self.midi[pad], @intCast(@mod(-@as(i64, delta), len)));
        for (self.midi[pad], 0..) |*slot, i| {
            if (slot.*) |*n| n.step = @intCast(i);
        }
    }

    pub fn padName(self: *const DrumMachine, pad: u8) []const u8 {
        if (pad >= max_pads) return "----";
        // A pad the "init" kit blanked stays materialized but holds no audio
        // (see `loadKitVariant`) - it reads as empty, same as one that was
        // never touched.
        if (self.pads[pad]) |*s| {
            if (s.pad.samples.len > 0) return s.clipName();
        }
        return "empty";
    }

    /// Current sequencer step - read by the UI to highlight the playhead.
    pub fn currentStep(self: *const DrumMachine) u16 {
        return self.current_step.load(.monotonic);
    }

    /// Spread `step` semitones per pad across the whole kit (pad 0 unchanged,
    /// pad 1 at `step`, ...) - the counterpart to `Slicer.spreadPitch`, for
    /// playing one chopped-up kit chromatically down the grid. Skips
    /// never-loaded pads: there is nothing to transpose there, and
    /// materializing 64 samplers to write a param would be a lot of memory
    /// for a no-op.
    pub fn spreadPitch(self: *DrumMachine, step: f32) void {
        for (&self.pads, 0..) |*slot, i| {
            const s = if (slot.*) |*live| live else continue;
            s.setParamAbsolute(pad_mod.pitch_id, step * @as(f32, @floatFromInt(i)));
        }
    }

    /// Encode a (pad, param) pair into the `set_param` id space.
    pub fn paramId(pad: u8, param: u8) u16 {
        return (@as(u16, pad) << 5) | (param & 0x1F);
    }

    const automation_sections = blk: {
        @setEvalBranchQuota(100_000);
        var sections: [max_pads][]const u8 = undefined;
        for (0..max_pads) |pad_idx| sections[pad_idx] = std.fmt.comptimePrint("PAD {d}", .{pad_idx + 1});
        break :blk sections;
    };

    pub const automatable_params = blk: {
        @setEvalBranchQuota(10_000);
        var params: [max_pads][Sampler.automatable_params.len]dsp.AutomatableParam = undefined;
        for (0..max_pads) |pad_idx| {
            for (Sampler.automatable_params, 0..) |param, param_idx| {
                params[pad_idx][param_idx] = .{
                    .id = paramId(@intCast(pad_idx), @intCast(param.id)),
                    .label = param.label,
                    .section = automation_sections[pad_idx],
                    .range = param.range,
                    .step = param.step,
                };
            }
        }
        break :blk params;
    };

    pub fn automatableParams(pad: u8) []const dsp.AutomatableParam {
        if (pad >= max_pads) return &.{};
        return &automatable_params[pad];
    }

    pub fn findAutomatableParam(id: u16) ?*const dsp.AutomatableParam {
        const pad: u8 = @intCast(id >> 5);
        if (pad >= max_pads) return null;
        for (&automatable_params[pad]) |*param| if (param.id == id) return param;
        return null;
    }

    /// Nudge a per-pad sampler param by `steps` (h/l = ±1, H/L = ±10). Runs on
    /// the audio thread via the `set_param` event so it never races the block
    /// reader, mirroring PolySynth.adjustParam. The pad index is the high bits
    /// of `id`; the param index is the low 5 bits (see `paramId`). Delegates
    /// straight to the pad's own Sampler.adjustParam - pads only ever receive
    /// param indices below `pad_param_count` (the drum grid never exposes
    /// Sampler's root-note/mono ids past it). A no-op on an unloaded (null)
    /// pad - nothing to nudge.
    pub fn adjustParam(self: *DrumMachine, id: u16, steps: i32) void {
        const pad_idx: u8 = @intCast(id >> 5);
        const param: u8 = @intCast(id & 0x1F);
        if (pad_idx >= max_pads) return;
        if (self.pads[pad_idx]) |*s| s.adjustParam(param, steps);
    }

    /// Absolute-value counterpart to `adjustParam`, same pad-encoded id
    /// space - for undo's capture/restore, delegating to the pad's own
    /// Sampler.setParamAbsolute. Runs on the audio thread via the
    /// `set_param_abs` event.
    pub fn setParamAbsolute(self: *DrumMachine, id: u16, value: f32) void {
        const pad_idx: u8 = @intCast(id >> 5);
        const param: u8 = @intCast(id & 0x1F);
        if (pad_idx >= max_pads) return;
        if (self.pads[pad_idx]) |*s| s.setParamAbsolute(param, value);
    }

    /// Current value of pad-encoded param `id` (see `paramId`), the read
    /// half of undo's capture/restore pair - null for an unloaded pad,
    /// matching `adjustParam`'s no-op there.
    pub fn paramValue(self: *const DrumMachine, id: u16) ?f32 {
        const pad_idx: u8 = @intCast(id >> 5);
        const param: u8 = @intCast(id & 0x1F);
        if (pad_idx >= max_pads) return null;
        if (self.pads[pad_idx]) |*s| return s.paramValue(param);
        return null;
    }

    // -----------------------------------------------------------------------
    // Sample loading (call from control side only, not while audio thread runs)

    /// Materialize pad `idx` if it's still null (never loaded), returning a
    /// pointer to it either way. Caller must have already bounds-checked
    /// `idx`.
    fn ensurePad(self: *DrumMachine, idx: u8) !*Sampler {
        if (self.pads[idx] == null) {
            self.pads[idx] = try Sampler.init(self.allocator, self.sample_rate);
        }
        return &self.pads[idx].?;
    }

    /// Replace pad `idx` with external mono f32 samples (must be allocated
    /// with `self.allocator`; the pad's Sampler takes ownership). Resets every
    /// other pad param to its default - used for a clean-slate kit pad, not
    /// user WAV loading (see `loadPadWav`, which preserves params).
    /// Materializes the pad if it was still null.
    pub fn setPadSamples(
        self: *DrumMachine,
        idx: u8,
        samples: []f32,
        name: []const u8,
    ) void {
        if (idx >= max_pads) {
            self.allocator.free(samples);
            return;
        }
        const pad = self.ensurePad(idx) catch {
            self.allocator.free(samples); // materialize failed - don't leak the caller's buffer
            return;
        };
        pad.setSamples(samples, name);
    }

    /// Regenerate the kit variant's pads (always the first 16 - kits are a
    /// 16-pad concept regardless of `max_pads`; see `dsp/drum_kit.zig`'s
    /// `variants` table) from procedural generators. Runs them directly into
    /// fresh pad buffers - nothing is read from disk or the binary's
    /// embedded assets, so extra kit flavours cost no shipped bytes. Marks
    /// every pad as non-user so it isn't exported to the audio cache.
    pub fn loadKitVariant(self: *DrumMachine, variant: *const drum_kit.KitVariant) !void {
        self.kit = variant.name;
        for (variant.pads, 0..) |slot, i| {
            const kind = slot.kind orelse {
                // Empty slot (the "init" kit): blank the pad rather than
                // unmaterialize it - a live machine's audio thread may be
                // inside this pad right now, and swapping in an empty buffer
                // goes through the same pad lock every other kit load uses.
                // A pad that was never materialized just stays null.
                if (self.pads[i] != null) {
                    const empty = try self.allocator.alloc(f32, 0);
                    self.setPadSamples(@intCast(i), empty, "");
                }
                self.choke_group[i] = 0;
                continue;
            };
            const samples = try drum_kit.genSlot(kind, slot.params, self.allocator, self.sample_rate);
            self.setPadSamples(@intCast(i), samples, slot.name);
            const p = &self.pads[i].?.pad;
            p.gain = slot.gain;
            // Slots that share a generator with their neighbour (kick-2, crash,
            // stick, ...) are told apart here rather than by duplicating the
            // generator; a slot with no tuning of its own resets these to the
            // untouched defaults the previous kit may have moved.
            p.pitch_semitones = slot.tune.pitch;
            p.end_norm = slot.tune.end;
            p.stretch_ratio = slot.tune.stretch;
            p.filter = slot.tune.filter;
        }
    }

    /// One pad's musical tuning, independent of its audio - what a
    /// user-saved kit persists (see tui/user_drum_kits.zig). Unlike
    /// `VariantSlot`, carries no generator/sample: applying a `PadTune`
    /// layers onto whatever audio a pad already holds rather than
    /// replacing it.
    pub const PadTune = struct {
        name: []const u8 = &.{},
        gain: f32 = 1.0,
        pan: f32 = 0.0,
        pitch_semitones: f32 = 0.0,
        attack_s: f32 = 0.001,
        decay_s: f32 = 0.0,
        sustain: f32 = 1.0,
        release_s: f32 = 0.005,
        env_curve: f32 = 0.0,
        fade_in_s: f32 = 0.0,
        fade_out_s: f32 = 0.0,
        fade_curve: f32 = 0.0,
        stretch_ratio: f32 = 1.0,
        filter: f32 = 0.0,
        gate: bool = false,
        choke_group: u8 = 0,
    };

    /// Snapshot pads 0-7's current tuning - the read half of a user kit
    /// save. A still-empty slot reports `PadTune{}` (its implicit defaults).
    pub fn tunePads(self: *const DrumMachine) [8]PadTune {
        var out: [8]PadTune = undefined;
        for (&out, 0..) |*t, i| {
            if (self.pads[i]) |*s| {
                t.* = .{
                    .name = s.clipName(),
                    .gain = s.pad.gain,
                    .pan = s.pad.pan,
                    .pitch_semitones = s.pad.pitch_semitones,
                    .attack_s = s.pad.attack_s,
                    .decay_s = s.pad.decay_s,
                    .sustain = s.pad.sustain,
                    .release_s = s.pad.release_s,
                    .env_curve = s.pad.env_curve,
                    .fade_in_s = s.pad.fade_in_s,
                    .fade_out_s = s.pad.fade_out_s,
                    .fade_curve = s.pad.fade_curve,
                    .stretch_ratio = s.pad.stretch_ratio,
                    .filter = s.pad.filter,
                    .gate = s.pad.gate,
                    .choke_group = self.choke_group[i],
                };
            } else {
                t.* = .{};
            }
        }
        return out;
    }

    /// Apply a saved tuning onto pads 0-7 - same 8-pad concept
    /// `loadKitVariant` uses, but skips a still-empty pad slot instead of
    /// materializing one, since a `PadTune` carries no audio to give it.
    pub fn applyPadTune(self: *DrumMachine, tune: *const [8]PadTune) void {
        for (tune, 0..) |t, i| {
            const pad = if (self.pads[i]) |*s| s else continue;
            pad.rename(t.name);
            // A saved kit is a hand-editable JSON file, so every value goes
            // through setParamAbsolute's clamp/non-finite guard rather than
            // landing raw in fields the audio thread reads. Ids are
            // dsp/pad.zig's shared table.
            // zig fmt: off
            pad.setParamAbsolute(7,  t.gain);
            pad.setParamAbsolute(8,  t.pan);
            pad.setParamAbsolute(pad_mod.pitch_id, t.pitch_semitones);
            pad.setParamAbsolute(3,  t.attack_s);
            pad.setParamAbsolute(4,  t.decay_s);
            pad.setParamAbsolute(5,  t.sustain);
            pad.setParamAbsolute(6,  t.release_s);
            pad.setParamAbsolute(pad_mod.env_curve_id, t.env_curve);
            pad.setParamAbsolute(10, t.fade_in_s);
            pad.setParamAbsolute(11, t.fade_out_s);
            pad.setParamAbsolute(pad_mod.fade_curve_id, t.fade_curve);
            pad.setParamAbsolute(pad_mod.stretch_id, t.stretch_ratio);
            pad.setParamAbsolute(13, t.filter);
            // zig fmt: on
            pad.pad.gate = t.gate;
            self.choke_group[i] = t.choke_group;
        }
    }

    /// Parse raw WAV bytes into pad `idx`, keeping its other params (pitch,
    /// trim, ADSR, gain, …) untouched - same as loading a new clip into the
    /// standalone Sampler. Resamples to engine rate if needed. Materializes
    /// the pad if it was still null.
    pub fn loadPadWav(self: *DrumMachine, idx: u8, wav_data: []const u8, name: []const u8) !void {
        if (idx >= max_pads) return;
        const was_empty = self.pads[idx] == null;
        const pad = try self.ensurePad(idx);
        pad.loadWav(wav_data, name) catch |err| {
            if (was_empty) {
                pad.deinit();
                self.pads[idx] = null;
            }
            return err;
        };
    }

    // -----------------------------------------------------------------------
    // Audio thread processing

    pub fn processBlock(self: *DrumMachine, buf: []Sample) void {
        const channels = 2;
        const frames: u32 = @intCast(buf.len / channels);

        while (!self.pad_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.pad_lock.unlock();

        if (self.transport.playing) {
            step_grid_ops.scanBlock(self, &self.pad_len, max_pads, frames);
        }

        // A pad with a pending capture request renders into its own scratch
        // buffer first (so its contribution can be copied out in isolation),
        // then that scratch sums into `buf` exactly like every other pad's
        // direct `processBlock(buf)` call - never rendered twice, so voice
        // state (envelopes, playback position) advances only once either
        // way. Every other pad takes the cheap direct-into-`buf` path,
        // unchanged from before per-pad capture existed.
        var pad_scratch: [types.max_block_frames * channels]Sample = undefined;
        for (&self.pads, 0..) |*p, i| {
            const s = if (p.*) |*sm| sm else continue;
            const pad_idx: u8 = @intCast(i);
            const capture = capture: {
                for (&self.pad_captures) |*c| {
                    if (c.*) |cap| if (cap.pad == pad_idx) break :capture cap.buf;
                }
                break :capture null;
            };
            if (capture) |dst| {
                const scratch = pad_scratch[0..buf.len];
                @memset(scratch, 0.0);
                s.processBlock(scratch);
                for (buf, scratch) |*o, sv| o.* += sv;
                @memcpy(dst, scratch);
            } else {
                s.processBlock(buf);
            }
        }
        self.pad_captures = [_]?PadCapture{null} ** max_pad_captures;
    }

    /// Schedule `note` on pad `p` - see `step_grid_ops.scheduleNote`.
    pub fn scheduleNote(self: *DrumMachine, p: u8, note: MidiNote, step_pos: f64, step_frames: f64) void {
        step_grid_ops.scheduleNote(self, p, note, step_pos, step_frames);
    }

    /// Emit the pads' scheduled hits - see `step_grid_ops.drainRolls`.
    pub fn drainRolls(self: *DrumMachine, pos_f: f64, frames: u32) void {
        step_grid_ops.drainRolls(self, pos_f, frames);
    }

    /// `tune` shifts this one hit by that many semitones, riding on top of
    /// the pad's own transpose - the Sampler already pitches a voice by
    /// `note - root_note`, so a tuned hit is just a different trigger note.
    /// `hold` is how long a gated pad plays before releasing itself, or -1 to
    /// wait for a note-off - see `Sampler.triggerHeld`.
    pub fn chokeTriggerTuned(self: *DrumMachine, p: u8, vel: f32, block_start: u32, tune: i8, hold: f64) void {
        const pad = if (self.pads[p]) |*s| s else return;
        const group = self.choke_group[p];
        if (group != 0) {
            for (&self.pads, 0..) |*other, i| {
                if (i != p and self.choke_group[i] == group) {
                    if (other.*) |*s| s.resetAll();
                }
            }
        }
        pad.resetAll();
        const note: u7 = @intCast(std.math.clamp(@as(i16, pad.root_note) + tune, 0, 127));
        pad.triggerHeld(note, vel, block_start, hold);
    }

    fn triggerPad(self: *DrumMachine, pad_idx: u8, vel: f32) void {
        if (pad_idx >= max_pads) return;
        self.chokeTriggerTuned(pad_idx, vel, 0, 0, -1.0);
    }

    fn releasePad(self: *DrumMachine, pad_idx: u8) void {
        if (pad_idx >= max_pads) return;
        if (self.pads[pad_idx]) |*s| s.releaseNote(s.root_note);
    }

    pub fn resetAll(self: *DrumMachine) void {
        for (&self.pads) |*p| if (p.*) |*s| s.resetAll();
        // Drop any roll tail with the voices it would have fed - a stop or a
        // seek shouldn't spit the rest of a roll out on the next block.
        for (&self.rolls) |*r| r.* = null;
        self.next_step_k = 0;
    }

    /// `deviceOf`'s expected name; forwards to `resetAll`.
    pub fn reset(self: *DrumMachine) void {
        self.resetAll();
    }

    pub fn handleEvent(self: *DrumMachine, ev: dsp.Event) void {
        switch (ev) {
            // zig fmt: off
            .note_on  => |e| self.triggerPad(e.note % max_pads, e.velocity),
            // Only a gated pad acts on this; a latched one-shot - the kit
            // default - plays out regardless. `triggerPad` fires the pad at
            // its own root note, so that is the voice to release.
            .note_off => |e| self.releasePad(e.note % max_pads),
            .set_param => |e| self.adjustParam(e.id, e.steps),
            .set_param_abs => |e| self.setParamAbsolute(e.id, e.value),
            .capture_pad => |e| self.addPadCapture(e.pad, e.buf),
            .automation_param => |e| if (e.instance_id == 0 and e.id <= std.math.maxInt(u16)) self.setParamAbsolute(@intCast(e.id), e.value),
            .cc, .pitch_bend, .set_mod_target, .clap_param, .vst3_param, .set_sidechain_buf => {},
            .all_off  => self.resetAll(),
            // zig fmt: on
        }
    }

    /// Stash a pad-capture request in the first free slot - extras past
    /// `max_pad_captures` are silently dropped, same "bank of N" convention
    /// `Engine.registerSidechainSource` already uses.
    fn addPadCapture(self: *DrumMachine, pad: u8, buf: []Sample) void {
        for (&self.pad_captures) |*c| {
            if (c.* == null) {
                c.* = .{ .pad = pad, .buf = buf };
                return;
            }
        }
    }
};

// -----------------------------------------------------------------------
// Tests

/// A machine with the "default" kit flavour on pads 0-15. A fresh `init` is
/// the blank "init" kit (no audio anywhere), so any test that renders or
/// tweaks a pad loads a kit first, exactly as the user would.
fn testMachine(transport: *const Transport) !DrumMachine {
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, transport);
    errdefer dm.deinit();
    try dm.loadKitVariant(drum_kit.byName("default").?);
    return dm;
}

test "a fresh machine is blank; a kit flavour fills pads 0-15, init empties them" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    // Blank slate: nothing materialized at all.
    for (0..DrumMachine.max_pads) |p| try std.testing.expect(dm.pads[p] == null);

    try dm.loadKitVariant(drum_kit.byName("default").?);
    // All 16 kit pads should generate and have samples + their default gain.
    for (0..16) |p| {
        try std.testing.expect(dm.pads[p].?.pad.samples.len > 0);
        try std.testing.expect(dm.pads[p].?.pad.gain > 0.0);
    }
    // Pads beyond the kit's 16 are lazily unmaterialized.
    for (16..DrumMachine.max_pads) |p| {
        try std.testing.expect(dm.pads[p] == null);
    }
    // Kick should have a non-zero peak.
    var peak: f32 = 0;
    for (dm.pads[0].?.pad.samples) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.01);
    // Hihat ships quieter than the kick by default.
    try std.testing.expect(dm.pads[4].?.pad.gain < dm.pads[0].?.pad.gain);
    // The second kick is the same generator retuned, not the same drum again.
    try std.testing.expectEqual(@as(f32, 3), dm.pads[1].?.pad.pitch_semitones);
    try std.testing.expect(dm.pads[1].?.pad.end_norm < 1.0);
    try std.testing.expectEqual(@as(f32, 0), dm.pads[0].?.pad.pitch_semitones);

    // Back to init: the kit pads stay materialized (the audio thread may be
    // inside one) but go silent, and their choke pairing is dropped.
    dm.choke_group[2] = 1;
    try dm.loadKitVariant(drum_kit.byName("init").?);
    for (0..16) |p| {
        try std.testing.expectEqual(@as(usize, 0), dm.pads[p].?.pad.samples.len);
        try std.testing.expectEqual(@as(u8, 0), dm.choke_group[p]);
    }
}

test "failed WAV load does not materialize an empty drum pad" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    try std.testing.expectError(error.NotAudioFile, dm.loadPadWav(0, "not a wav at all", "broken"));
    try std.testing.expect(dm.pads[0] == null);
}

test "out-of-range pad sample assignment releases ownership" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    const samples = try std.testing.allocator.alloc(f32, 16);
    dm.setPadSamples(DrumMachine.max_pads, samples, "invalid");
}

test "step sequencer fires pads at correct boundaries" {
    var transport: Transport = .{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    var dm = try testMachine(&transport);
    defer dm.deinit();

    // Clear all defaults; enable only pad 0 on step 0
    for (0..DrumMachine.max_pads) |p| dm.clearPad(@intCast(p));
    dm.toggleStep(0, 0); // step 0 active

    // At 120bpm, 16th note = 6000 frames. Start playing at frame 0.
    transport.play();
    var buf: [512]Sample = undefined; // 256 frames * 2 channels
    @memset(&buf, 0.0);
    dm.processBlock(&buf);

    // Step 0 fires at frame 0 - pad 0 should be audible
    var peak: f32 = 0;
    for (buf) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.01);
    transport.advance(256);

    // Advance far past step 0 boundary (6000 frames); no second fire yet
    while (transport.position_frames < 5900) {
        @memset(&buf, 0.0);
        dm.processBlock(&buf);
        transport.advance(256);
    }

    // Reset voice to isolate the next trigger
    dm.resetAll();
    // Advance through the step-1 boundary (which has no active pad)
    while (transport.position_frames < 6256) {
        @memset(&buf, 0.0);
        dm.processBlock(&buf);
        transport.advance(256);
    }
    // After exactly one loop (32 steps × 6000 = 192000 frames) step 0 fires again
    while (transport.position_frames < 192_000) {
        @memset(&buf, 0.0);
        dm.processBlock(&buf);
        transport.advance(256);
    }
    @memset(&buf, 0.0);
    dm.processBlock(&buf);
    peak = 0;
    for (buf) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.01);
}

test "pad grid stores canonical MIDI notes" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    dm.toggleStep(3, 7);
    dm.setStepVel(3, 7, 95);

    const midi = dm.midi[3][7].?;
    try std.testing.expectEqual(@as(u7, 3), midi.pitch);
    try std.testing.expectEqual(@as(u16, 7), midi.step);
    try std.testing.expectEqual(@as(u16, 1), midi.duration_steps);
    try std.testing.expectEqual(@as(u7, 95), midi.velocity);

    var notes: [64]Note = undefined;
    try std.testing.expectEqual(@as(u16, 1), dm.copyPadMidi(3, &notes));
    try std.testing.expectApproxEqAbs(@as(f64, 7.0) / @as(f64, @floatFromInt(DrumMachine.ticks_per_beat)), notes[0].start_beat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 95.0 / 127.0), notes[0].velocity, 1e-6);
}

test "clearKit wipes every pad and reports the hit count removed" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    dm.setStepCount(8);
    dm.toggleStep(0, 0);
    dm.toggleStep(0, 4);
    dm.toggleStep(3, 2);

    try std.testing.expectEqual(@as(u32, 3), dm.clearKit());
    for (0..DrumMachine.max_pads) |pad| {
        for (0..8) |step| try std.testing.expect(!dm.stepActive(@intCast(pad), @intCast(step)));
    }

    // An already-empty kit reports 0, not an error.
    try std.testing.expectEqual(@as(u32, 0), dm.clearKit());
}

test "humanizeVelocity jitters active hits within bounds; 0% is a no-op" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    dm.setStepCount(8);
    dm.toggleStep(0, 0);
    dm.setStepVel(0, 0, 100);
    dm.toggleStep(1, 4);
    dm.setStepVel(1, 4, 60);

    dm.humanizeVelocity(0.0, 1);
    try std.testing.expectEqual(@as(u8, 100), dm.stepVel(0, 0));
    try std.testing.expectEqual(@as(u8, 60), dm.stepVel(1, 4));

    dm.humanizeVelocity(50.0, 42);
    try std.testing.expect(dm.stepVel(0, 0) >= 1 and dm.stepVel(0, 0) <= 127);
    try std.testing.expect(dm.stepVel(1, 4) >= 1 and dm.stepVel(1, 4) <= 127);
    // Untouched (empty) steps stay silent - only active hits get jittered.
    try std.testing.expect(!dm.stepActive(2, 0));

    // At least one of the two hits actually moved.
    try std.testing.expect(dm.stepVel(0, 0) != 100 or dm.stepVel(1, 4) != 60);
}

test "humanizeVelocity ignores non-finite amounts" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    dm.toggleStep(0, 0);
    dm.setStepVel(0, 0, 77);
    dm.humanizeVelocity(std.math.nan(f64), 1);
    try std.testing.expectEqual(@as(u8, 77), dm.stepVel(0, 0));
}

test "euclidPad spreads pulses evenly, honors rotation, clears on zero" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    // E(3,8): the tresillo - hits on steps 0, 3, 6.
    dm.setStepCount(8);
    dm.euclidPad(0, 3, 0);
    for (0..8) |s| {
        const expect_on = s == 0 or s == 3 or s == 6;
        try std.testing.expectEqual(expect_on, dm.stepActive(0, @intCast(s)));
    }

    // Rotation shifts the whole figure: first hit lands on step 2.
    dm.euclidPad(0, 3, 2);
    for (0..8) |s| {
        const expect_on = s == 2 or s == 5 or s == 0;
        try std.testing.expectEqual(expect_on, dm.stepActive(0, @intCast(s)));
    }

    // 0 pulses clears; pulses > steps saturate to every step.
    dm.euclidPad(0, 0, 0);
    for (0..8) |s| try std.testing.expect(!dm.stepActive(0, @intCast(s)));
    dm.euclidPad(0, 99, 0);
    for (0..8) |s| try std.testing.expect(dm.stepActive(0, @intCast(s)));

    // Stored notes carry the destination step (grid position is canonical).
    try std.testing.expectEqual(@as(u16, 5), dm.midi[0][5].?.step);
}

test "velocityRampPad interpolates hits by step position" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    dm.setStepCount(16);
    dm.toggleStep(2, 0);
    dm.toggleStep(2, 4);
    dm.toggleStep(2, 8);

    try std.testing.expectEqual(@as(u16, 3), dm.velocityRampPad(2, 20, 120));
    try std.testing.expectEqual(@as(u8, 20), dm.stepVel(2, 0));
    try std.testing.expectEqual(@as(u8, 70), dm.stepVel(2, 4));
    try std.testing.expectEqual(@as(u8, 120), dm.stepVel(2, 8));

    // Lone hit gets the target; 0 clamps to 1 (silence is x/X's job).
    dm.clearPad(2);
    dm.toggleStep(2, 3);
    try std.testing.expectEqual(@as(u16, 1), dm.velocityRampPad(2, 50, 0));
    try std.testing.expectEqual(@as(u8, 1), dm.stepVel(2, 3));

    // Empty row touches nothing.
    try std.testing.expectEqual(@as(u16, 0), dm.velocityRampPad(5, 20, 120));
}

test "reversePattern mirrors every pad's hits, duration-aware" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    dm.setStepCount(8);
    dm.toggleStep(0, 0); // kick on the one
    dm.setStepVel(0, 0, 100);
    dm.toggleStep(1, 2); // snare
    dm.midi[3][1] = .{ .pitch = 3, .step = 1, .duration_steps = 3 }; // spans [1,4)

    dm.reversePattern();
    // 1-step hits land on the mirrored slot (N-1-step).
    try std.testing.expect(dm.stepActive(0, 7) and !dm.stepActive(0, 0));
    try std.testing.expectEqual(@as(u8, 100), dm.stepVel(0, 7));
    try std.testing.expect(dm.stepActive(1, 5) and !dm.stepActive(1, 2));
    // The 3-step note ends where it used to begin: [1,4) -> [4,7), step 4.
    try std.testing.expectEqual(@as(u16, 4), dm.midi[3][4].?.step);
    try std.testing.expectEqual(@as(u16, 3), dm.midi[3][4].?.duration_steps);

    // Reversing twice restores the original pattern.
    dm.reversePattern();
    try std.testing.expect(dm.stepActive(0, 0) and dm.stepActive(1, 2));
    try std.testing.expectEqual(@as(u16, 1), dm.midi[3][1].?.step);
}

test "rotatePad wraps hits and rewrites their canonical step" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    dm.setStepCount(8);
    dm.toggleStep(2, 0);
    dm.setStepVel(2, 0, 80);
    dm.toggleStep(2, 6);

    dm.rotatePad(2, 3); // 0 -> 3, 6 -> wraps to 1
    try std.testing.expect(dm.stepActive(2, 3) and dm.stepActive(2, 1));
    try std.testing.expect(!dm.stepActive(2, 0) and !dm.stepActive(2, 6));
    try std.testing.expectEqual(@as(u8, 80), dm.stepVel(2, 3));
    try std.testing.expectEqual(@as(u16, 3), dm.midi[2][3].?.step);
    try std.testing.expectEqual(@as(u16, 1), dm.midi[2][1].?.step);

    dm.rotatePad(2, -3); // and back
    try std.testing.expect(dm.stepActive(2, 0) and dm.stepActive(2, 6));
}

test "song mode fires the clip covering the playhead" {
    var transport: Transport = .{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    var dm = try testMachine(&transport);
    defer dm.deinit();

    // Clear the default groove; song mode reads only song_clips.
    for (0..DrumMachine.max_pads) |p| dm.clearPad(@intCast(p));

    // Two bars long. A single clip in bar 1 (steps 16..31) fires pad 0 on its
    // first step; bar 0 is empty.
    var clip_midi = try DrumMachine.allocMidi(std.testing.allocator, 16);
    clip_midi[0][0] = DrumMachine.gridNote(0, 0, DrumMachine.vel_full); // local step 0
    const clips = [_]DrumMachine.SongClip{.{
        // zig fmt: off
        .start_step = 16, .span_steps = 16, .step_count = 16, .midi = clip_midi,
        // zig fmt: on
    }};
    dm.setSongClips(&clips, 32, 4);
    dm.song_mode = true;
    transport.play();

    var buf: [512]Sample = undefined; // 256 frames

    // At frame 0 (bar 0) nothing should sound.
    @memset(&buf, 0.0);
    dm.processBlock(&buf);
    var peak: f32 = 0;
    for (buf) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak < 0.01);

    // Jump to bar 1's downbeat: step 16 = 16 * 6000 frames = 96_000.
    dm.resetAll();
    transport.seekFrames(96_000);
    @memset(&buf, 0.0);
    dm.processBlock(&buf);
    peak = 0;
    for (buf) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.01);
}

test "song clip overflow releases transferred MIDI rows" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    var clips: [DrumMachine.max_song_clips + 1]DrumMachine.SongClip = undefined;
    for (&clips) |*clip| clip.* = .{
        .start_step = 0,
        .span_steps = 16,
        .step_count = 16,
        .midi = [_][]?DrumMachine.MidiNote{&.{}} ** DrumMachine.max_pads,
    };
    clips[DrumMachine.max_song_clips].midi[0] = try std.testing.allocator.alloc(?DrumMachine.MidiNote, 1);
    clips[DrumMachine.max_song_clips].midi[0][0] = null;

    dm.setSongClips(&clips, 16, 4);
    try std.testing.expectEqual(DrumMachine.max_song_clips, dm.song_clip_count);
}

test "song mode swing follows the clip's sixteenth-note grid" {
    var transport: Transport = .{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    var dm = try testMachine(&transport);
    defer dm.deinit();

    var clip_midi = try DrumMachine.allocMidi(std.testing.allocator, 16);
    clip_midi[0][1] = DrumMachine.gridNote(0, 1, DrumMachine.vel_full);
    const clip = DrumMachine.SongClip{
        .start_step = 0,
        .span_steps = 32,
        .step_count = 16,
        .steps_per_beat = 4,
        .midi = clip_midi,
    };
    dm.setSongClips(&.{clip}, 32, 32);
    dm.song_mode = true;
    dm.adjustSwing(100.0);
    transport.play();

    var buf: [512]Sample = undefined;
    while (transport.position_frames < 8960) {
        @memset(&buf, 0.0);
        dm.processBlock(&buf);
        var peak: f32 = 0;
        for (buf) |sample| peak = @max(peak, @abs(sample));
        try std.testing.expect(peak < 0.01);
        transport.advance(256);
    }
    try std.testing.expect(dm.rolls[0] != null);
    try std.testing.expectApproxEqAbs(@as(f64, 9000), dm.rolls[0].?.next_pos, 1e-9);

    @memset(&buf, 0.0);
    dm.processBlock(&buf);
    var peak: f32 = 0;
    for (buf) |sample| peak = @max(peak, @abs(sample));
    try std.testing.expect(peak > 0.01);
}

test "adjustSwing ignores non-finite deltas" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try testMachine(&transport);
    defer dm.deinit();
    dm.adjustSwing(12.0);
    dm.adjustSwing(std.math.nan(f32));
    try std.testing.expectEqual(@as(f32, 62.0), dm.swing.load(.monotonic));
}

test "note_on triggers pad directly" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try testMachine(&transport);
    defer dm.deinit();

    dm.resetAll();
    const dev = dm.device();
    dev.sendEvent(.{ .note_on = .{ .note = 0, .velocity = 1.0 } });

    var buf: [512]Sample = undefined;
    @memset(&buf, 0.0);
    dm.processBlock(&buf);

    var peak: f32 = 0;
    for (buf) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.01);
}

test "step velocity: cycles presets, nudges, toggling resets, shrink masks" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    dm.toggleStep(0, 5);
    try std.testing.expectEqual(@as(u8, 127), dm.stepVel(0, 5)); // new steps are full

    // c walks 127 → 95 → 63 → 31 and wraps back to 127.
    dm.cycleStepVel(0, 5);
    try std.testing.expectEqual(@as(u8, 95), dm.stepVel(0, 5));
    dm.cycleStepVel(0, 5);
    dm.cycleStepVel(0, 5);
    try std.testing.expectEqual(@as(u8, 31), dm.stepVel(0, 5));
    dm.cycleStepVel(0, 5);
    try std.testing.expectEqual(@as(u8, 127), dm.stepVel(0, 5));

    // Level → gain mapping.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), DrumMachine.velGain(127), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), DrumMachine.velGain(31), 1e-2);

    // {/} nudge the full 1-127 range, clamped at both ends.
    dm.setStepVel(0, 5, 5);
    dm.nudgeStepVel(0, 5, -10);
    try std.testing.expectEqual(@as(u8, 1), dm.stepVel(0, 5));
    dm.setStepVel(0, 5, 120);
    dm.nudgeStepVel(0, 5, 20);
    try std.testing.expectEqual(@as(u8, 127), dm.stepVel(0, 5));

    // Retoggling a step brings it back at full velocity.
    dm.setStepVel(0, 5, 31);
    dm.toggleStep(0, 5); // off
    dm.toggleStep(0, 5); // on again
    try std.testing.expectEqual(@as(u8, 127), dm.stepVel(0, 5));

    // Velocity past a shrink doesn't survive a re-grow.
    dm.setStepCount(32);
    dm.toggleStep(0, 20);
    dm.setStepVel(0, 20, 63);
    dm.setStepCount(16);
    dm.setStepCount(32);
    try std.testing.expectEqual(@as(u8, 127), dm.stepVel(0, 20));
}

test "voice velocity scales the rendered level" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try testMachine(&transport);
    defer dm.deinit();

    var buf: [512]Sample = undefined;

    var voice: pad_mod.Voice = .{ .active = true, .played = 0, .block_start = 0, .vel = 1.0 };
    @memset(&buf, 0.0);
    pad_mod.renderVoice(&voice, &dm.pads[0].?.pad, &buf, 2, 256, 48_000.0);
    var peak_full: f32 = 0;
    for (buf) |s| peak_full = @max(peak_full, @abs(s));

    voice = .{ .active = true, .played = 0, .block_start = 0, .vel = 0.25 };
    @memset(&buf, 0.0);
    pad_mod.renderVoice(&voice, &dm.pads[0].?.pad, &buf, 2, 256, 48_000.0);
    var peak_quiet: f32 = 0;
    for (buf) |s| peak_quiet = @max(peak_quiet, @abs(s));

    try std.testing.expect(peak_full > 0.01);
    try std.testing.expectApproxEqAbs(peak_full * 0.25, peak_quiet, 1e-4);
}

test "choke group silences other pads sharing it" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try testMachine(&transport);
    defer dm.deinit();
    dm.resetAll();

    // Pads 4 and 5 share a fresh choke group; pad 6 is unrelated.
    dm.choke_group[4] = 2;
    dm.choke_group[5] = 2;

    const dev = dm.device();
    dev.sendEvent(.{ .note_on = .{ .note = 4, .velocity = 1.0 } });
    try std.testing.expect(dm.pads[4].?.voices[0].active);

    dev.sendEvent(.{ .note_on = .{ .note = 5, .velocity = 1.0 } });
    try std.testing.expect(!dm.pads[4].?.voices[0].active); // choked by pad 5
    try std.testing.expect(dm.pads[5].?.voices[0].active);

    // An unrelated pad (no group) doesn't touch pad 5's still-ringing voice.
    dev.sendEvent(.{ .note_on = .{ .note = 6, .velocity = 1.0 } });
    try std.testing.expect(dm.pads[5].?.voices[0].active);
}

test "cycleChokeGroup wraps through none..max" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    try std.testing.expectEqual(@as(u8, 0), dm.choke_group[0]);
    var i: u8 = 0;
    while (i < DrumMachine.max_choke_groups) : (i += 1) {
        dm.cycleChokeGroup(0);
        try std.testing.expectEqual(i + 1, dm.choke_group[0]);
    }
    dm.cycleChokeGroup(0); // one more step wraps max → none
    try std.testing.expectEqual(@as(u8, 0), dm.choke_group[0]);
}

test "variants keep per-step velocity" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    for (0..DrumMachine.max_pads) |p| dm.clearPad(@intCast(p));
    dm.toggleStep(0, 0);
    dm.setStepVel(0, 0, 63); // variant A: ~50%

    _ = dm.addVariant(); // B copies A, then diverges
    try std.testing.expectEqual(@as(u8, 63), dm.stepVel(0, 0));
    dm.setStepVel(0, 0, 31);

    dm.selectVariant(0);
    try std.testing.expectEqual(@as(u8, 63), dm.stepVel(0, 0));
    dm.selectVariant(1);
    try std.testing.expectEqual(@as(u8, 31), dm.stepVel(0, 0));
}

test "toggleStep flips step activity" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    dm.toggleStep(0, 3);
    try std.testing.expect(dm.stepActive(0, 3));
    dm.toggleStep(0, 3);
    try std.testing.expect(!dm.stepActive(0, 3));
}

test "applying an empty variant materializes blank rows" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    dm.applyVariant(.{ .step_count = 16, .steps_per_beat = 4 });
    try std.testing.expectEqual(@as(u16, 16), dm.step_count);
    try std.testing.expectEqual(@as(usize, 16), dm.midi[0].len);
    try std.testing.expect(!dm.stepActive(0, 15));
}

test "variants: add copies, edits stay isolated, select round-trips" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    for (0..DrumMachine.max_pads) |p| dm.clearPad(@intCast(p));
    dm.toggleStep(0, 0); // variant A: pad 0 step 0

    // New variant starts as a copy of A, then diverges.
    try std.testing.expect(dm.addVariant());
    try std.testing.expectEqual(@as(u8, 1), dm.variant);
    try std.testing.expect(dm.stepActive(0, 0));
    dm.toggleStep(0, 0);
    dm.toggleStep(1, 4); // variant B: pad 1 step 4 only

    // Back to A: the original pattern, untouched by B's edits.
    dm.selectVariant(0);
    try std.testing.expect(dm.stepActive(0, 0));
    try std.testing.expect(!dm.stepActive(1, 4));

    // Forward to B again: its own edits survived the switch.
    dm.selectVariant(1);
    try std.testing.expect(!dm.stepActive(0, 0));
    try std.testing.expect(dm.stepActive(1, 4));
}

test "variants: step count is per-variant" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    try std.testing.expect(dm.addVariant());
    dm.setStepCount(24);
    dm.selectVariant(0);
    try std.testing.expectEqual(@as(u16, DrumMachine.ticks_per_beat) * 8, dm.step_count); // default, untouched
    dm.selectVariant(1);
    try std.testing.expectEqual(@as(u16, 24), dm.step_count);
}

test "variants: cycle wraps and remove shifts the bank down" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    try std.testing.expect(!dm.removeVariant()); // can't drop the only one
    dm.cycleVariant(1); // single variant: no-op
    try std.testing.expectEqual(@as(u8, 0), dm.variant);

    _ = dm.addVariant(); // B
    _ = dm.addVariant(); // C - mark it
    for (0..DrumMachine.max_pads) |p| dm.clearPad(@intCast(p));
    dm.toggleStep(7, 7);

    dm.cycleVariant(1); // wraps C → A
    try std.testing.expectEqual(@as(u8, 0), dm.variant);
    dm.cycleVariant(-1); // wraps A → C
    try std.testing.expectEqual(@as(u8, 2), dm.variant);

    // Remove B: C shifts into slot 1 and stays findable.
    dm.selectVariant(1);
    try std.testing.expect(dm.removeVariant());
    try std.testing.expectEqual(@as(u8, 2), dm.variant_count);
    dm.selectVariant(1);
    try std.testing.expect(dm.stepActive(7, 7));
}

test "variants: bank fills at max_variants" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    var added: u8 = 0;
    while (dm.addVariant()) added += 1;
    try std.testing.expectEqual(DrumMachine.max_variants - 1, added);
    try std.testing.expectEqual(DrumMachine.max_variants, dm.variant_count);
}

test "variantData reads the active variant from the live state" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    for (0..DrumMachine.max_pads) |p| dm.clearPad(@intCast(p));
    dm.toggleStep(3, 9); // edit after the bank slot was last synced
    const active = dm.variantData(dm.variant);
    try std.testing.expectEqual(@as(u8, 127), active.midi[3][9].?.velocity);
}

test "setStepCount discards steps beyond the new count" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    dm.setStepCount(32);
    dm.toggleStep(0, 20);
    dm.setStepCount(16); // shrink: step 20 must not survive
    dm.setStepCount(32); // grow back
    try std.testing.expect(!dm.stepActive(0, 20));
}

test "step count grows well past the old 64-step ceiling and the sequencer fires the last step" {
    var transport: Transport = .{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    var dm = try testMachine(&transport);
    defer dm.deinit();

    // 200 steps: > 3x the old 64-step ceiling, well within u16 headroom.
    dm.setStepCount(200);
    try std.testing.expectEqual(@as(u16, 200), dm.step_count);

    const last: u16 = 199;
    dm.toggleStep(0, last);
    try std.testing.expect(dm.stepActive(0, last));
    dm.setStepVel(0, last, 31);
    try std.testing.expectEqual(@as(u8, 31), dm.stepVel(0, last));

    // At 120 BPM, one canonical tick is 750 frames.
    transport.play();
    transport.seekFrames(750 * @as(u64, last) - 50);
    var buf: [512]Sample = undefined; // 256 frames
    dm.resetAll();
    @memset(&buf, 0.0);
    dm.processBlock(&buf);
    var peak: f32 = 0;
    for (buf) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.01);
}

test "per-step tune clamps to the pad pitch range and only touches live steps" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    // An empty step has nothing to tune and reports 0.
    try std.testing.expectEqual(@as(i8, 0), dm.stepTune(0, 3));
    dm.nudgeStepTune(0, 3, 5);
    try std.testing.expectEqual(@as(i8, 0), dm.stepTune(0, 3));

    dm.toggleStep(0, 3);
    dm.nudgeStepTune(0, 3, 5);
    try std.testing.expectEqual(@as(i8, 5), dm.stepTune(0, 3));
    dm.nudgeStepTune(0, 3, -12);
    try std.testing.expectEqual(@as(i8, -7), dm.stepTune(0, 3));

    // Same ±24 ceiling the pad's own pitch param clamps to.
    dm.nudgeStepTune(0, 3, 500);
    try std.testing.expectEqual(@as(i8, 24), dm.stepTune(0, 3));
    dm.nudgeStepTune(0, 3, -500);
    try std.testing.expectEqual(@as(i8, -24), dm.stepTune(0, 3));

    // Tune is per step, not per pad: its neighbour on the same row is
    // untouched.
    dm.toggleStep(0, 4);
    try std.testing.expectEqual(@as(i8, 0), dm.stepTune(0, 4));
}

test "a pad's own loop length wraps that row early and drifts against the rest" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();
    dm.setStepCount(16);

    // Default: every row follows the pattern.
    try std.testing.expectEqual(@as(u16, 16), dm.padSteps(0, 16));

    dm.setPadLen(0, 7);
    try std.testing.expectEqual(@as(u16, 7), dm.padSteps(0, 16));
    // Untouched rows are unaffected - that's the whole point.
    try std.testing.expectEqual(@as(u16, 16), dm.padSteps(1, 16));

    // A length at or past the pattern means "follow the pattern" again,
    // and a length past a *shorter* pattern is clamped at use time rather
    // than being lost on write.
    dm.setPadLen(0, 16);
    try std.testing.expectEqual(@as(u16, 0), dm.pad_len[0]);
    dm.setPadLen(0, 12);
    try std.testing.expectEqual(@as(u16, 8), dm.padSteps(0, 8));
    try std.testing.expectEqual(@as(u16, 12), dm.padSteps(0, 16));

    // Nudging down from "follows the pattern" lands one below it, not at 1.
    dm.setPadLen(0, 0);
    dm.nudgePadLen(0, -1);
    try std.testing.expectEqual(@as(u16, 15), dm.padSteps(0, 16));
    dm.nudgePadLen(0, 99);
    try std.testing.expectEqual(@as(u16, 0), dm.pad_len[0]);
}

test "a roll spreads its hits across the step and survives block boundaries" {
    var transport: Transport = .{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();
    dm.setStepCount(16);
    dm.toggleStep(0, 0);
    dm.midi[0][0].?.retrig = 4;

    // At 120 BPM a 1/16 step is 6000 frames, so a 4-hit roll spaces hits
    // 1500 frames apart - well past one 256-frame block.
    const fps = transport.framesPerStep(4);
    try std.testing.expectApproxEqAbs(@as(f64, 6000), fps, 1.0);

    // Fire the step, then walk blocks and count the tail hits the roll
    // schedules. Counting through drainRolls directly keeps this about the
    // scheduling rather than about voice rendering.
    dm.scheduleNote(0, dm.midi[0][0].?, 0.0, fps);
    try std.testing.expectEqual(@as(u8, 4), dm.rolls[0].?.remaining);
    try std.testing.expectApproxEqAbs(@as(f64, 1500), dm.rolls[0].?.interval, 1.0);

    var pos: f64 = 0;
    var blocks: usize = 0;
    while (dm.rolls[0] != null and blocks < 64) : (blocks += 1) {
        dm.drainRolls(pos, 256);
        pos += 256;
    }
    // The last hit sits at 4500 frames, ~18 blocks in - the roll outlives
    // the block that started it, which is the whole reason it's scheduled.
    try std.testing.expect(blocks > 15);
    try std.testing.expectEqual(@as(?DrumMachine.Roll, null), dm.rolls[0]);

    // A plain step schedules exactly one hit, which the first drain clears.
    dm.midi[0][0].?.retrig = 0;
    dm.scheduleNote(0, dm.midi[0][0].?, 0.0, fps);
    try std.testing.expectEqual(@as(u8, 1), dm.rolls[0].?.remaining);
    dm.drainRolls(0, 256);
    try std.testing.expectEqual(@as(?DrumMachine.Roll, null), dm.rolls[0]);

    // A stop drops the tail instead of dumping it on the next block.
    dm.midi[0][0].?.retrig = 8;
    dm.scheduleNote(0, dm.midi[0][0].?, 0.0, fps);
    try std.testing.expect(dm.rolls[0] != null);
    dm.resetAll();
    try std.testing.expectEqual(@as(?DrumMachine.Roll, null), dm.rolls[0]);
}

test "micro-timing shifts a hit off its own step boundary, both directions" {
    var transport: Transport = .{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();
    dm.setStepCount(16);
    dm.toggleStep(0, 4);

    const fps = transport.framesPerStep(4); // 6000 frames at 120 BPM
    const step_pos = 4.0 * fps;

    // Straight: the hit sits exactly on the boundary.
    dm.scheduleNote(0, dm.midi[0][4].?, step_pos, fps);
    try std.testing.expectApproxEqAbs(step_pos, dm.rolls[0].?.next_pos, 1.0);

    // Late by a quarter step.
    dm.setStepMicro(0, 4, 25);
    dm.scheduleNote(0, dm.midi[0][4].?, step_pos, fps);
    try std.testing.expectApproxEqAbs(step_pos + fps * 0.25, dm.rolls[0].?.next_pos, 1.0);

    // Early: the hit lands BEFORE its own boundary, which is the case a
    // boundary-ordered scan could never emit at the right frame.
    dm.setStepMicro(0, 4, -50);
    dm.scheduleNote(0, dm.midi[0][4].?, step_pos, fps);
    try std.testing.expectApproxEqAbs(step_pos - fps * 0.5, dm.rolls[0].?.next_pos, 1.0);
    try std.testing.expect(dm.rolls[0].?.next_pos < step_pos);

    // Clamped at half a step - past that it would cross into the neighbour.
    dm.setStepMicro(0, 4, 300);
    try std.testing.expectEqual(@as(i8, 50), dm.stepMicro(0, 4));
    dm.setStepMicro(0, 4, -300);
    try std.testing.expectEqual(@as(i8, -50), dm.stepMicro(0, 4));

    // An empty step has no timing to shift.
    try std.testing.expectEqual(@as(i8, 0), dm.stepMicro(0, 5));
    dm.nudgeStepMicro(0, 5, 10);
    try std.testing.expectEqual(@as(i8, 0), dm.stepMicro(0, 5));
}

test "a hit just behind the playhead is clamped, one a whole block back is dropped" {
    var transport: Transport = .{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();
    dm.toggleStep(0, 0);

    // Scheduled 10 frames before the block start: still emitted (clamped to
    // frame 0), not silently lost.
    dm.scheduleNote(0, dm.midi[0][0].?, 990.0, 6000.0);
    dm.drainRolls(1000, 256);
    try std.testing.expectEqual(@as(?DrumMachine.Roll, null), dm.rolls[0]);

    // Scheduled far enough back that a seek must have jumped it: consumed
    // without firing, rather than dumped on the boundary.
    dm.scheduleNote(0, dm.midi[0][0].?, 0.0, 6000.0);
    dm.drainRolls(100_000, 256);
    try std.testing.expectEqual(@as(?DrumMachine.Roll, null), dm.rolls[0]);
}

test "a gated pad stops at its step; a live hit waits for the note-off" {
    var transport: Transport = .{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();
    const samples = try std.testing.allocator.alloc(f32, 1024);
    @memset(samples, 0.5);
    dm.setPadSamples(0, samples, "kick");
    dm.pads[0].?.pad.gate = true;
    dm.toggleStep(0, 0);

    // 120 bpm at 4 steps per beat: 6000 frames a step.
    dm.scheduleNote(0, dm.midi[0][0].?, 0.0, 6000.0);
    dm.drainRolls(0, 256);
    try std.testing.expectApproxEqAbs(@as(f64, 6000.0), dm.pads[0].?.voices[0].v.hold_frames, 1e-6);

    // Played by hand instead: nothing to end at, so it waits for the key.
    dm.device().sendEvent(.{ .note_on = .{ .note = 0, .velocity = 1.0 } });
    try std.testing.expect(dm.pads[0].?.voices[0].v.hold_frames < 0.0);
    try std.testing.expect(dm.pads[0].?.voices[0].v.release_frames < 0.0);
    dm.device().sendEvent(.{ .note_off = .{ .note = 0 } });
    try std.testing.expectEqual(@as(f64, 0.0), dm.pads[0].?.voices[0].v.release_frames);
}

test "trig conditions gate a step by pass count and the fill switch" {
    const Cond = DrumMachine.Cond;
    // 1:2 fires on passes 0, 2, 4 …; 2:2 on 1, 3, 5 …
    try std.testing.expect(Cond.a1b2.holds(0, false));
    try std.testing.expect(!Cond.a1b2.holds(1, false));
    try std.testing.expect(!Cond.a2b2.holds(0, false));
    try std.testing.expect(Cond.a2b2.holds(1, false));
    // 2:4 is the second of every four.
    try std.testing.expect(Cond.a2b4.holds(1, false));
    try std.testing.expect(Cond.a2b4.holds(5, false));
    try std.testing.expect(!Cond.a2b4.holds(2, false));

    try std.testing.expect(Cond.first.holds(0, false));
    try std.testing.expect(!Cond.first.holds(1, false));
    try std.testing.expect(!Cond.not_first.holds(0, false));
    try std.testing.expect(Cond.not_first.holds(7, false));

    // The fill pair reads the switch and ignores the pass entirely.
    try std.testing.expect(Cond.fill.holds(3, true));
    try std.testing.expect(!Cond.fill.holds(3, false));
    try std.testing.expect(Cond.not_fill.holds(3, false));
    try std.testing.expect(!Cond.not_fill.holds(3, true));

    // Every label is set, so the status line can't print an empty condition.
    for (std.enums.values(Cond)) |c| try std.testing.expect(c.label().len > 0);
}

test "step probability rolls repeatably and lands near the requested rate" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();
    dm.toggleStep(0, 0);

    // 100% and 0% never touch the dice.
    try std.testing.expect(DrumMachine.trigFires(dm.midi[0][0].?, 0, 12345, 0, false));
    dm.midi[0][0].?.prob = 0;
    try std.testing.expect(!DrumMachine.trigFires(dm.midi[0][0].?, 0, 12345, 0, false));

    // A 50% step: same absolute step gives the same answer twice (no hidden
    // RNG state), and over many steps it lands near half.
    dm.midi[0][0].?.prob = 50;
    const note = dm.midi[0][0].?;
    try std.testing.expectEqual(
        DrumMachine.trigFires(note, 0, 999, 0, false),
        DrumMachine.trigFires(note, 0, 999, 0, false),
    );
    var hits: usize = 0;
    for (0..2000) |k| {
        if (DrumMachine.trigFires(note, 0, k, 0, false)) hits += 1;
    }
    try std.testing.expect(hits > 850 and hits < 1150);

    // Condition and probability are ANDed: an off-pass never fires however
    // the dice land.
    dm.midi[0][0].?.cond = .a1b2;
    dm.midi[0][0].?.prob = 100;
    const conditional = dm.midi[0][0].?;
    try std.testing.expect(DrumMachine.trigFires(conditional, 0, 0, 0, false));
    try std.testing.expect(!DrumMachine.trigFires(conditional, 0, 0, 1, false));
}

test "adjustParam decodes pad/param and clamps" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try testMachine(&transport);
    defer dm.deinit();

    // pad 2, param 2 = pitch; +3 semitones
    dm.adjustParam(DrumMachine.paramId(2, 2), 3);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), dm.pads[2].?.pad.pitch_semitones, 1e-4);

    // start never crosses end
    dm.adjustParam(DrumMachine.paramId(0, 0), 1000); // start up hard
    try std.testing.expect(dm.pads[0].?.pad.start_norm < dm.pads[0].?.pad.end_norm);

    // reverse toggles on any nonzero step
    const before = dm.pads[1].?.pad.reverse;
    dm.adjustParam(DrumMachine.paramId(1, 9), 1);
    try std.testing.expectEqual(!before, dm.pads[1].?.pad.reverse);
}

test "paramId's widened 5-bit param field round-trips a pad up to the new mod ids" {
    // pad 63, param 18 (mod_dest) - the widened boundary this stride exists
    // for; a 4-bit field couldn't have addressed either coordinate.
    const id = DrumMachine.paramId(63, 18);
    try std.testing.expectEqual(@as(u16, 63), id >> 5);
    try std.testing.expectEqual(@as(u16, 18), id & 0x1F);

    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try testMachine(&transport);
    defer dm.deinit();

    dm.setParamAbsolute(DrumMachine.paramId(0, pad_mod.mod_dest_id), 2.0); // 2 = .gain
    try std.testing.expectEqual(pad_mod.ModDest.gain, dm.pads[0].?.pad.mod_dest);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), dm.paramValue(DrumMachine.paramId(0, pad_mod.mod_dest_id)).?, 1e-6);
}

test "automation targets one drum pad parameter" {
    const id = DrumMachine.paramId(2, 7);
    const param = DrumMachine.findAutomatableParam(id).?;
    try std.testing.expectEqualStrings("GAIN", param.label);
    try std.testing.expectEqualStrings("PAD 3", param.section);

    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try testMachine(&transport);
    defer dm.deinit();
    const other_gain = dm.pads[1].?.pad.gain;
    dm.handleEvent(.{ .automation_param = .{ .id = id, .value = 0.25 } });
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), dm.pads[2].?.pad.gain, 1e-6);
    try std.testing.expectApproxEqAbs(other_gain, dm.pads[1].?.pad.gain, 1e-6);
}

test "applying a hand-edited kit clamps its values" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try testMachine(&transport);
    defer dm.deinit();

    var tune: [8]DrumMachine.PadTune = [_]DrumMachine.PadTune{.{}} ** 8;
    tune[0] = .{ .name = "kick", .gain = 500, .pan = -9, .pitch_semitones = 99, .stretch_ratio = 0, .release_s = std.math.inf(f32), .env_curve = -8 };
    dm.applyPadTune(&tune);

    const p = &dm.pads[0].?.pad;
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), p.gain, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), p.pan, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 24.0), p.pitch_semitones, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), p.stretch_ratio, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), p.env_curve, 1e-6);
    // Non-finite is dropped, not clamped: the previous value survives.
    try std.testing.expect(std.math.isFinite(p.release_s));
}

test "region trim shortens the voice" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try testMachine(&transport);
    defer dm.deinit();

    // Trim pad 0 to the first 10% of the clip, then trigger it.
    dm.pads[0].?.pad.end_norm = 0.1;
    const region = dm.pads[0].?.pad.samples.len / 10;

    dm.resetAll();
    var voice: pad_mod.Voice = .{ .active = true, .played = 0, .block_start = 0 };
    var buf: [4096]Sample = undefined;
    // Render enough frames to exceed the trimmed region; the voice must end.
    var rendered: usize = 0;
    while (voice.active and rendered < dm.pads[0].?.pad.samples.len) : (rendered += buf.len / 2) {
        @memset(&buf, 0.0);
        pad_mod.renderVoice(&voice, &dm.pads[0].?.pad, &buf, 2, buf.len / 2, 48_000.0);
    }
    try std.testing.expect(!voice.active);
    // It stopped near the region length, well before the full clip.
    try std.testing.expect(rendered < dm.pads[0].?.pad.samples.len);
    try std.testing.expect(region < dm.pads[0].?.pad.samples.len);
}

test "pitch up plays the region faster" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try testMachine(&transport);
    defer dm.deinit();

    var buf: [256]Sample = undefined;

    // Baseline: count active frames at unity pitch.
    dm.pads[0].?.pad.pitch_semitones = 0.0;
    var voice: pad_mod.Voice = .{ .active = true, .played = 0, .block_start = 0 };
    var unity_frames: usize = 0;
    while (voice.active and unity_frames < 1_000_000) : (unity_frames += 128) {
        @memset(&buf, 0.0);
        pad_mod.renderVoice(&voice, &dm.pads[0].?.pad, &buf, 2, 128, 48_000.0);
    }

    // Pitched up an octave should consume the region in roughly half the frames.
    dm.pads[0].?.pad.pitch_semitones = 12.0;
    voice = .{ .active = true, .played = 0, .block_start = 0 };
    var fast_frames: usize = 0;
    while (voice.active and fast_frames < 1_000_000) : (fast_frames += 128) {
        @memset(&buf, 0.0);
        pad_mod.renderVoice(&voice, &dm.pads[0].?.pad, &buf, 2, 128, 48_000.0);
    }
    try std.testing.expect(fast_frames < unity_frames);
}

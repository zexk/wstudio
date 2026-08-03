//! Step-sequenced sample chopper - the "Slicer" instrument. One shared
//! sample buffer is chopped into up to `max_slices` independently-
//! triggerable regions ("slices"), each with its own start/end/pitch/gain/
//! pan/reverse/ADSR - the same per-region params `dsp/sampler.zig`'s
//! standalone Sampler and `dsp/drum_sampler.zig`'s drum pads already carry,
//! sharing `dsp/pad.zig`'s `renderVoice` engine unmodified.
//!
//! Unlike DrumMachine (`max_pads` independent Samplers, each owning its own
//! clip buffer), every slice's `Pad.samples` here aliases the SAME
//! underlying buffer (a slice is just `{ptr, len}`, so this costs nothing) -
//! `sliceInto(n)` just sets each slice's `start_norm`/`end_norm` to an equal
//! 1/n fraction of the one shared clip. That's the whole trick that makes
//! "one sample, N independently playable chops" cheap.
//!
//! Each slice's step data is a compact MIDI note (`midi`, a per-slice,
//! heap-owned slice sized to `step_count`) - the same architecture
//! `dsp/drum_sampler.zig` moved to, and for the same reason: the old `u64`
//! bitmask plus parallel `vel` array is exactly why steps were once
//! hard-capped at 64 (one word's bit width, not a chosen musical limit).
//! `step_count`/`steps_per_beat` now set the pattern's length and the grid's
//! zoom, and growing either just grows the per-slice slices. The note type
//! itself (`MidiNote`, and the `Cond` trig conditions with it) is
//! DrumMachine's, imported rather than re-declared, so a step means exactly
//! the same thing in both grids and the shared editors/renderers can treat
//! the two machines alike.
//!
//! The step *sequencer* still deliberately does NOT share code with
//! DrumMachine's, despite the conceptual overlap (both fire per-step
//! triggers with swing and per-step velocity, hold pattern variants A-H,
//! carry per-row choke groups and per-row loop lengths, and flatten
//! arrangement clips into a SongClip timeline for song mode) - DrumMachine
//! is the heaviest-tested, most atomics-delicate file in the codebase (see
//! its own doc comment), and entangling a second consumer with its internals
//! is a real risk. This file mirrors those algorithms independently; only
//! the note *data* is shared.
//!
//! `midi`/`Variant.midi`/`SongClip.midi` are heap-owned per-slice slices
//! rather than inline `[max_slices][max_steps]` arrays for the same reason
//! DrumMachine's are: at u16's ceiling an inline array would blow up
//! `@sizeOf(Slicer)` across the 8-slot variant bank into multi-MB territory,
//! and `init`/`dupe` return this struct by value. Resizes take `sample_lock`
//! (already held by `processBlock` for the whole block) around the swap so
//! the audio thread never observes a torn slice header; per-cell writes stay
//! lock-free, the same tolerated convention as `choke_group`.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const Transport = @import("../transport.zig").Transport;
const pad_mod = @import("pad.zig");
const Pad = pad_mod.Pad;
const Voice = pad_mod.Voice;
const DrumMachine = @import("drum_sampler.zig").DrumMachine;
const Note = @import("pattern.zig").Note;

const Sample = types.Sample;

pub const Slicer = struct {
    pub const max_slices: u8 = 64;
    /// Step-grid capacity: the u16 step index's own ceiling, not a musical
    /// wall - see `DrumMachine.max_steps`, which this mirrors.
    pub const max_steps: u16 = std.math.maxInt(u16);

    /// The drum machine's note and trig-condition types, reused verbatim: a
    /// slicer step and a drum step carry the same payload (velocity, length,
    /// chance, condition, micro-timing, retrig, tune), so sharing the type
    /// is what lets the grids, the editors and the save format treat them
    /// alike instead of growing a second near-identical set of each.
    pub const MidiNote = DrumMachine.MidiNote;
    pub const Cond = DrumMachine.Cond;
    /// The tail of an in-flight roll - see `DrumMachine.Roll`.
    pub const Roll = DrumMachine.Roll;
    /// Max pattern variants (A..H) one slicer can hold - same bank size as
    /// `DrumMachine.max_variants`.
    pub const max_variants: u8 = 8;
    /// Max clips one lane can hold for song-mode playback (see `song_clips`).
    pub const max_song_clips: u16 = 256;
    /// Max choke groups a slice can belong to (0 = no group, ungated).
    pub const max_choke_groups: u8 = 4;
    /// Small per-slice voice pool - slices are short one-shots retriggered
    /// often (stutters, rolls), so a few overlapping voices covers real use
    /// without Sampler's full 16 (a slicer track can have up to 64 of these
    /// pools live at once, unlike Sampler's single pad).
    pub const max_voices_per_slice: u8 = 4;
    /// `set_param`/`set_param_abs` ids are `slice << 4 | param` - same shape
    /// DrumMachine.paramId uses for its own per-pad params.
    pub const param_stride: u16 = 16;

    pub const vel_full: u8 = 127;
    /// Named preset bands `cycleStepVel` steps through - same ladder as
    /// DrumMachine's, so the two grids' `c` key feels identical. Same goes
    /// for the chance and roll ladders below.
    const vel_presets = [_]u8{ 127, 95, 63, 31 };
    const prob_presets = [_]u8{ 100, 75, 50, 25, 10 };
    const retrig_presets = [_]u8{ 0, 2, 3, 4, 6, 8 };
    pub fn velGain(level: u8) f32 {
        return @as(f32, @floatFromInt(level)) / @as(f32, @floatFromInt(vel_full));
    }

    pub const swing_min: f32 = 50.0;
    pub const swing_max: f32 = 75.0;

    const SliceVoice = struct {
        active: bool = false,
        age: u64 = 0,
        v: Voice = .{},
    };

    /// A step's note tagged with the row that owns it - `pitch` is the slice
    /// index, the same "pad tag, not a pitch" convention
    /// `DrumMachine.gridNote` documents.
    pub const gridNote = DrumMachine.gridNote;

    /// Allocate `max_slices` fresh per-slice note slices, each `len` long and
    /// null-filled. The building block every resize/dupe path shares.
    pub fn allocMidi(allocator: std.mem.Allocator, len: u16) ![max_slices][]?MidiNote {
        var out: [max_slices][]?MidiNote = undefined;
        var i: usize = 0;
        errdefer for (out[0..i]) |s| allocator.free(s);
        while (i < max_slices) : (i += 1) {
            out[i] = try allocator.alloc(?MidiNote, len);
            @memset(out[i], null);
        }
        return out;
    }

    /// Free every slice's row. Safe (a no-op) on still-empty (`&.{}`) slots,
    /// e.g. a never-materialized variant bank slot.
    pub fn freeMidi(allocator: std.mem.Allocator, midi: *[max_slices][]?MidiNote) void {
        for (midi) |s| allocator.free(s);
    }

    /// Deep-copy every slice's row into fresh allocations.
    pub fn dupeMidi(allocator: std.mem.Allocator, src: *const [max_slices][]?MidiNote) ![max_slices][]?MidiNote {
        var out: [max_slices][]?MidiNote = undefined;
        var i: usize = 0;
        errdefer for (out[0..i]) |s| allocator.free(s);
        while (i < max_slices) : (i += 1) {
            out[i] = try allocator.dupe(?MidiNote, src[i]);
        }
        return out;
    }

    /// One pattern variant: a bank slot for the step grid. The active variant
    /// lives in the live `midi`/`step_count` fields; inactive ones rest here
    /// as plain data (control thread only). `midi` is heap-owned - see the
    /// file's top doc comment. Mirrors `DrumMachine.Variant`, rows indexed by
    /// slice instead of pad.
    pub const Variant = struct {
        midi: [max_slices][]?MidiNote = [_][]?MidiNote{&.{}} ** max_slices,
        step_count: u16 = 16,
        /// Number of sequencer steps in one quarter-note beat.
        steps_per_beat: u8 = 4,
    };

    /// A slicer clip flattened onto the arrangement's step timeline - same
    /// shape and repeat-to-fill-span semantics as `DrumMachine.SongClip` (the
    /// audio thread reads these under `sample_lock`, which `processBlock`
    /// already holds). `midi` is heap-owned: `setSongClips` takes ownership
    /// of whatever is passed in (build fresh rows per call, e.g. via
    /// `dupeMidi`, and don't reuse or free them yourself afterward).
    pub const SongClip = struct {
        start_step: u32,
        span_steps: u32,
        step_count: u16,
        steps_per_beat: u8 = 4,
        midi: [max_slices][]?MidiNote,
    };

    allocator: std.mem.Allocator,
    sample_rate: u32,
    transport: *const Transport,

    /// Guards `samples` (and every slice's aliasing `Pad.samples`) against
    /// concurrent reads (audio thread) and writes (control thread calling
    /// `loadWav`/`sliceInto`) - mirrors `Sampler.pad_lock`. Ordinary per-slice
    /// param edits (gain, pan, start/end nudge, ...) are plain unlocked
    /// writes, same race-tolerant convention `Sampler.adjustParam`/
    /// `DrumMachine.choke_group` already use - worst case one stale block,
    /// never a crash, since nothing here reallocates.
    sample_lock: std.atomic.Mutex = .unlocked,
    /// The one shared clip every slice's `Pad.samples` aliases.
    samples: []f32,
    name: [8]u8 = [_]u8{' '} ** 8,
    /// True when the audio was loaded by the user (`:load-slice`) - only
    /// user audio is exported to the project's sample sidecar on save, same
    /// convention `Pad.user_sample` documents.
    user_sample: bool = false,

    /// Per-slice params. `slices[i].samples` always aliases `self.samples` -
    /// never independently allocated or freed; `deinit` frees `self.samples`
    /// exactly once. Slots at/past `slice_count` are inert (never triggered,
    /// never rendered) but still point at valid memory, so no branch needs a
    /// null-check the way DrumMachine's lazily-materialized pads do.
    slices: [max_slices]Pad = undefined,
    /// How many of `slices` are actually chopped out. Zero until `:slice`
    /// runs - an unsliced Slicer is silent, nothing to trigger, same as a
    /// never-loaded drum pad.
    slice_count: u8 = 0,
    voices: [max_slices][max_voices_per_slice]SliceVoice = undefined,
    next_age: u64 = 0,

    /// Canonical live pattern: one heap-owned, `step_count`-long row per
    /// slice. Control thread writes (resize under `sample_lock`; per-cell
    /// writes lock-free, matching `choke_group`'s convention), audio thread
    /// reads directly in `processBlock`. Always mirrors the active variant;
    /// edits land here and are synced back to `variants[variant]` when
    /// switching away.
    midi: [max_slices][]?MidiNote,
    /// Cached row length of every entry in `midi` - control thread writes,
    /// audio thread reads (plain field, no atomics, same convention as
    /// `choke_group`).
    step_count: u16 = 16,
    /// Native timing resolution of the active pattern. Four is 1/16 notes;
    /// 32 is 1/128 notes.
    steps_per_beat: u8 = 4,
    swing: std.atomic.Value(f32) = .init(50.0),

    // ── Pattern variants (control thread only) ──────────────────────────────
    /// Bank slots. Slot `variant` is stale while active - read it through
    /// `variantData`, which pulls the live state instead. Only slots
    /// `0..variant_count` ever hold a real allocation; every mutator that
    /// touches this array must iterate that range, not `0..max_variants` -
    /// see `DrumMachine.variants`, which has the same ownership rule.
    variants: [max_variants]Variant = [_]Variant{.{}} ** max_variants,
    variant_count: u8 = 1,
    /// Index of the active variant (the one in the live `midi`).
    variant: u8 = 0,

    /// Per-slice choke group (0 = none). Grouped slices opt back into the
    /// classic cut-the-previous-hit behavior `triggerSlice` alone
    /// deliberately skips - see `chokeTrigger`.
    choke_group: [max_slices]u8 = [_]u8{0} ** max_slices,
    /// Per-slice loop length in steps, 0 = follow the pattern - Elektron's
    /// per-track lengths, see `DrumMachine.pad_len` for the full rationale.
    /// Machine-level (not per-variant) and clamped at use time, same as
    /// `choke_group`/`swing`, which is also why song mode picks it up free.
    slice_len: [max_slices]u16 = [_]u16{0} ** max_slices,
    /// Performance switch the `fill`/`not_fill` trig conditions read - see
    /// `DrumMachine.fill_on`.
    fill_on: std.atomic.Value(bool) = .init(false),
    /// Hits the sequencer has decided on but not yet emitted, one slot per
    /// slice (audio thread only) - a roll's tail lands blocks after the step
    /// that started it, and a `micro`-shifted hit can land before its own
    /// step boundary. See `DrumMachine.rolls`.
    rolls: [max_slices]?Roll = [_]?Roll{null} ** max_slices,

    /// When true, processBlock fires from `song_clips` under the playhead
    /// instead of looping the live pattern - same switch DrumMachine has.
    song_mode: bool = false,
    /// Heap slice of length `max_song_clips` (owned, freed in deinit) for
    /// the same struct-size reason as `DrumMachine.song_clips`.
    song_clips: []SongClip,
    song_clip_count: u16 = 0,
    /// Whole-arrangement length in steps; silent past this (no wrap).
    song_length_steps: u32 = 0,
    /// Resolution of the absolute song timeline. Live slicer patterns stay at
    /// four steps per beat; arrangement clips use 32 so every editor grid
    /// position remains exact.
    song_steps_per_beat: u8 = 4,

    // Audio-thread-only state:
    next_step_k: u64 = 0,
    current_step: std.atomic.Value(u16) = .init(0),

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32, transport: *const Transport) !Slicer {
        const samples = try allocator.alloc(f32, 0);
        errdefer allocator.free(samples);
        const song_clips = try allocator.alloc(SongClip, max_song_clips);
        errdefer allocator.free(song_clips);
        const default_step_count: u16 = 16;
        var midi = try allocMidi(allocator, default_step_count);
        errdefer freeMidi(allocator, &midi);
        var self: Slicer = .{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .transport = transport,
            .samples = samples,
            .song_clips = song_clips,
            .midi = midi,
            .step_count = default_step_count,
        };
        for (&self.slices) |*p| p.* = .{ .samples = samples };
        // zig fmt: off
        for (&self.voices) |*row| for (row) |*v| { v.* = .{}; };
        // zig fmt: on
        return self;
    }

    pub fn deinit(self: *Slicer) void {
        self.allocator.free(self.samples);
        for (self.song_clips[0..self.song_clip_count]) |*clip| freeMidi(self.allocator, &clip.midi);
        self.allocator.free(self.song_clips);
        freeMidi(self.allocator, &self.midi);
        for (self.variants[0..self.variant_count]) |*v| freeMidi(self.allocator, &v.midi);
    }

    /// Deep copy for track duplication: the clip audio and every heap-owned
    /// note row get fresh allocations so the two slicers share no memory;
    /// every slice re-aliases the NEW buffer. Voice state resets - no
    /// mid-flight hit worth carrying. Song-mode state isn't carried, same as
    /// `DrumMachine.dupe`: the caller rebuilds it from the arrangement.
    pub fn dupe(self: *const Slicer) !Slicer {
        var copy = try Slicer.init(self.allocator, self.sample_rate, self.transport);
        errdefer copy.deinit();

        const samples = try self.allocator.dupe(f32, self.samples);
        self.allocator.free(copy.samples);
        copy.samples = samples;
        copy.slices = self.slices;
        copy.slice_count = self.slice_count;
        for (&copy.slices) |*p| p.samples = copy.samples;
        copy.name = self.name;
        copy.user_sample = self.user_sample;

        const midi = try dupeMidi(self.allocator, &self.midi);
        freeMidi(copy.allocator, &copy.midi);
        copy.midi = midi;
        copy.step_count = self.step_count;
        copy.steps_per_beat = self.steps_per_beat;
        copy.swing.store(self.swing.load(.monotonic), .monotonic);
        copy.choke_group = self.choke_group;
        copy.slice_len = self.slice_len;

        // Target count first (not after the loop) so a mid-loop allocation
        // failure leaves `copy.deinit()` freeing exactly the intended range -
        // see `DrumMachine.dupe`'s identical comment.
        copy.variant_count = self.variant_count;
        for (self.variants[0..self.variant_count], 0..) |*src_slot, i| {
            copy.variants[i] = .{
                .midi = try dupeMidi(self.allocator, &src_slot.midi),
                .step_count = src_slot.step_count,
                .steps_per_beat = src_slot.steps_per_beat,
            };
        }
        copy.variant = self.variant;
        return copy;
    }

    pub const device = dsp.deviceOf(@This());

    pub fn clipName(self: *const Slicer) []const u8 {
        return pad_mod.trimmedName(&self.name);
    }

    /// Set the display name directly, independent of the loaded audio -
    /// mirrors `Sampler.rename`, and is what `:rename` reaches while a
    /// slicer editor is open.
    pub fn rename(self: *Slicer, name: []const u8) void {
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        self.name = pad_mod.fixedName(name);
    }

    // -----------------------------------------------------------------------
    // Loading + slicing (control thread only, not while audio thread runs)

    /// Parse raw WAV bytes into the shared clip. Resamples to engine rate if
    /// needed. When `reset_slices` is true (the interactive `:load-slice`
    /// path), clears every slice - the old boundaries (fractions of the OLD
    /// clip's length) are meaningless against new audio, so the user
    /// re-chops with `:slice` afterward. `reset_slices = false` is for
    /// restoring a saved project: persist.zig applies each slice's saved
    /// start/end/gain/etc. BEFORE the audio bytes are read back from the
    /// sample sidecar, so this must only re-point every slice's `.samples`
    /// at the fresh buffer without touching `slice_count` or any slice's own
    /// params, or the just-restored slicing would be wiped out from under it.
    /// Best-effort check for whether a clip is loaded - used by editors
    /// deciding whether to show an empty state (or, for the GUI/TUI slicer
    /// entry point, jump straight to the file browser instead). Not the
    /// audio thread's own gate, so a missed lock just reports "has audio"
    /// rather than spinning.
    pub fn hasAudio(self: *Slicer) bool {
        if (!self.sample_lock.tryLock()) return true;
        defer self.sample_lock.unlock();
        return self.samples.len > 0;
    }

    pub fn loadWav(self: *Slicer, wav_data: []const u8, name: []const u8, reset_slices: bool) !void {
        const samples = try pad_mod.decodeWav(self.allocator, wav_data, self.sample_rate);

        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        self.allocator.free(self.samples);
        self.samples = samples;
        self.name = pad_mod.fixedName(name);
        self.user_sample = true;
        if (reset_slices) {
            self.slice_count = 0;
            for (&self.slices) |*p| p.* = .{ .samples = samples };
        } else {
            for (&self.slices) |*p| {
                p.samples = samples;
                pad_mod.clampTimeParamsToDuration(p, self.sample_rate);
            }
        }
        self.clearVoices();
    }

    /// Equal-divide the shared clip into `n` regions (clamped to
    /// `1..=max_slices`), each a fresh default-params slice spanning its own
    /// 1/n fraction. Existing per-slice pattern/velocity data past the new
    /// `n` stays in the atomics (harmless - `processBlock` only ever reads
    /// pattern bits for `slice_idx < slice_count`) so re-slicing to a larger
    /// `n` later doesn't lose earlier programming.
    pub fn sliceInto(self: *Slicer, n: u8) void {
        const count = std.math.clamp(n, 1, max_slices);
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        const step_norm = 1.0 / @as(f32, @floatFromInt(count));
        for (0..count) |i| {
            self.slices[i] = .{
                .samples = self.samples,
                .start_norm = @as(f32, @floatFromInt(i)) * step_norm,
                .end_norm = @as(f32, @floatFromInt(i + 1)) * step_norm,
                .retrig = true,
            };
        }
        self.slice_count = count;
        self.clearVoices();
    }

    /// Re-chop at detected transients (the MPC "slice at attacks" workflow):
    /// contiguous fresh-params regions, one per onset, first always anchored
    /// at 0. `sensitivity` 1 (only the hardest hits) .. 9 (every flutter),
    /// 5 = default. Returns the new slice count (1 = nothing detected, the
    /// whole clip as one slice).
    pub fn chopTransients(self: *Slicer, sensitivity: u8) u8 {
        var positions: [max_slices]f32 = undefined;
        const n = detectOnsets(self.samples, self.sample_rate, sensitivity, &positions);
        self.chopAt(positions[0..n]);
        return self.slice_count;
    }

    /// Serato's "Set Random": chop into `n` slices at random boundaries
    /// rather than at transients or on an even grid - the dice roll that
    /// turns a loop you know too well into chops you would never have drawn
    /// by hand. Cuts are drawn from a grid four times finer than the slice
    /// count: uneven enough to be worth rolling, coarse enough that no slice
    /// comes out too short to hear. Partial Fisher-Yates over that grid
    /// rather than rejection sampling, so a repeated draw can't spin.
    /// Returns the new slice count.
    pub fn chopRandom(self: *Slicer, n: u8, rand: std.Random) u8 {
        const count = std.math.clamp(n, 1, max_slices);
        if (count == 1) {
            self.sliceInto(1);
            return self.slice_count;
        }
        const res: usize = @as(usize, count) * 4;
        var grid: [@as(usize, max_slices) * 4 - 1]u8 = undefined;
        const pool = grid[0 .. res - 1];
        for (pool, 0..) |*g, i| g.* = @intCast(i + 1);
        for (0..count - 1) |i| {
            const j = i + rand.uintLessThan(usize, pool.len - i);
            std.mem.swap(u8, &pool[i], &pool[j]);
        }
        const cuts = pool[0 .. count - 1];
        std.mem.sort(u8, cuts, {}, std.sort.asc(u8));

        var positions: [max_slices]f32 = undefined;
        positions[0] = 0.0;
        const res_f: f32 = @floatFromInt(res);
        for (cuts, 1..) |c, k| positions[k] = @as(f32, @floatFromInt(c)) / res_f;
        self.chopAt(positions[0..count]);
        return self.slice_count;
    }

    /// Spread `step` semitones per slice across the whole chop (slice 0
    /// unchanged, slice 1 at `step`, ...) - Serato's "pitch a chop across
    /// the pads" trick, which turns one hit into a playable scale down the
    /// grid. Clamped to the pad pitch range, so a big step flattens out at
    /// the top rather than wrapping.
    pub fn spreadPitch(self: *Slicer, step: f32) void {
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        for (0..self.slice_count) |i| {
            const semis = step * @as(f32, @floatFromInt(i));
            pad_mod.setParamAbsolute(&self.slices[i], pad_mod.pitch_id, semis);
        }
    }

    /// Set every live slice's `stretch_ratio` at once - the slices all view
    /// one clip, so fitting that clip to the project tempo is a single
    /// setting, not a per-slice edit. Same clamp as a manual nudge.
    pub fn stretchAll(self: *Slicer, ratio: f32) void {
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        for (0..self.slice_count) |i| {
            pad_mod.setParamAbsolute(&self.slices[i], pad_mod.stretch_id, ratio);
        }
    }

    /// Set every live slice's pitch together, matching `stretchAll`.
    pub fn pitchAll(self: *Slicer, semitones: f32) void {
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        for (0..self.slice_count) |i| {
            pad_mod.setParamAbsolute(&self.slices[i], pad_mod.pitch_id, semitones);
        }
    }

    /// Cycle all live slices to the next play mode as one. Mixed state
    /// resolves to whatever comes after slice 0's mode, so the clip always
    /// lands uniform in one keypress.
    pub fn cycleModeAll(self: *Slicer) pad_mod.PlayMode {
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        if (self.slice_count == 0) return .one_shot;
        const n = pad_mod.play_mode_names.len;
        const next: pad_mod.PlayMode = @enumFromInt((@intFromEnum(pad_mod.playMode(&self.slices[0])) + 1) % n);
        for (self.slices[0..self.slice_count]) |*slice| pad_mod.setPlayMode(slice, next);
        return next;
    }

    /// Chop into contiguous regions whose starts are `positions` (ascending
    /// fractions of the clip, first entry treated as 0); each region ends
    /// where the next begins, the last at 1.0.
    pub fn chopAt(self: *Slicer, positions: []const f32) void {
        const count: u8 = @intCast(std.math.clamp(positions.len, 1, max_slices));
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        var start: f32 = 0.0;
        for (0..count) |i| {
            const next_raw = if (i + 1 < count) positions[i + 1] else 1.0;
            const next = if (std.math.isFinite(next_raw))
                std.math.clamp(next_raw, start, 1.0)
            else
                start;
            self.slices[i] = .{
                .samples = self.samples,
                .start_norm = start,
                .end_norm = if (i + 1 < count) next else 1.0,
                .retrig = true,
            };
            start = next;
        }
        self.slice_count = count;
        self.clearVoices();
    }

    /// Split the cursor slice at its region midpoint: the new right half is
    /// inserted at `idx + 1` (inheriting the left half's params), and every
    /// later slice - including its pattern/velocity rows - shifts down one.
    /// Returns false when full or `idx` is out of range.
    pub fn splitSlice(self: *Slicer, idx: u8) bool {
        if (idx >= self.slice_count or self.slice_count >= max_slices) return false;
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        var i: usize = self.slice_count;
        while (i > idx + 1) : (i -= 1) {
            self.slices[i] = self.slices[i - 1];
            // Rows move by swapping the slice headers, not by copying cells:
            // every row is the same `step_count` length, so a swap is both
            // cheaper and allocation-free.
            std.mem.swap([]?MidiNote, &self.midi[i], &self.midi[i - 1]);
            self.slice_len[i] = self.slice_len[i - 1];
            self.choke_group[i] = self.choke_group[i - 1];
        }
        const left = &self.slices[idx];
        const mid = left.start_norm + (left.end_norm - left.start_norm) / 2.0;
        var right = left.*;
        right.start_norm = mid;
        left.end_norm = mid;
        self.slices[idx + 1] = right;
        // The new right half starts silent - it inherited its sound from the
        // left (params and choke group), not its programming.
        self.clearRow(idx + 1);
        self.slice_len[idx + 1] = 0;
        self.choke_group[idx + 1] = self.choke_group[idx];
        self.slice_count += 1;
        self.clearVoices();
        return true;
    }

    /// Merge the cursor slice with the one after it: the region extends to
    /// the right slice's end, both rows are combined (the louder note wins
    /// where two land on the same step), and every later slice shifts up one.
    /// Returns false when `idx` is the last slice or out of range.
    pub fn mergeSliceRight(self: *Slicer, idx: u8) bool {
        if (idx >= self.slice_count or @as(u16, idx) + 1 >= self.slice_count) return false;
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        self.slices[idx].end_norm = self.slices[idx + 1].end_norm;
        for (self.midi[idx], self.midi[idx + 1]) |*dst, src| {
            const incoming = src orelse continue;
            if (dst.*) |kept| {
                if (incoming.velocity <= kept.velocity) continue;
            }
            var moved = incoming;
            moved.pitch = @intCast(idx); // the note now belongs to this row
            dst.* = moved;
        }
        var i: usize = idx + 1;
        while (i + 1 < self.slice_count) : (i += 1) {
            self.slices[i] = self.slices[i + 1];
            std.mem.swap([]?MidiNote, &self.midi[i], &self.midi[i + 1]);
            self.slice_len[i] = self.slice_len[i + 1];
            self.choke_group[i] = self.choke_group[i + 1];
        }
        self.clearRow(self.slice_count - 1);
        self.slice_len[self.slice_count - 1] = 0;
        self.choke_group[self.slice_count - 1] = 0;
        self.slice_count -= 1;
        self.clearVoices();
        return true;
    }

    /// Blank one slice's row in place (no reallocation) - the shared tail of
    /// `clearSlice` and every row-shifting edit above.
    fn clearRow(self: *Slicer, slice: u8) void {
        if (slice >= max_slices) return;
        @memset(self.midi[slice], null);
    }

    /// Kill every voice after audio or slice regions change.
    fn clearVoices(self: *Slicer) void {
        // zig fmt: off
        for (&self.voices) |*row| for (row) |*v| { v.* = .{}; };
        // zig fmt: on
    }

    // -----------------------------------------------------------------------
    // Param editing - `id` is `slice << 4 | param` (see `param_stride`).

    pub fn adjustParam(self: *Slicer, id: u16, steps: i32) void {
        const slice_idx = id >> 4;
        const param: u8 = @intCast(id & 0x0F);
        if (slice_idx >= max_slices) return;
        pad_mod.adjustParam(&self.slices[slice_idx], param, steps);
        if (pad_mod.affectsTimeRange(param)) pad_mod.clampTimeParamsToDuration(&self.slices[slice_idx], self.sample_rate);
    }

    pub fn paramId(slice: u8, param: u8) u16 {
        return (@as(u16, slice) << 4) | (param & 0x0F);
    }

    /// Set slice-encoded param `id` to an absolute value (same clamps as
    /// `adjustParam`'s per-step nudges) - undo's restore half, mirroring
    /// `DrumMachine.setParamAbsolute`.
    pub fn setParamAbsolute(self: *Slicer, id: u16, value: f32) void {
        const slice_idx = id >> 4;
        const param: u8 = @intCast(id & 0x0F);
        if (slice_idx >= max_slices) return;
        pad_mod.setParamAbsolute(&self.slices[slice_idx], param, value);
        if (pad_mod.affectsTimeRange(param)) pad_mod.clampTimeParamsToDuration(&self.slices[slice_idx], self.sample_rate);
    }

    /// Current value of slice-encoded param `id`, in `setParamAbsolute`'s
    /// encoding (reverse as 0/1) - undo's capture half. Null past the live
    /// slice count, so undo skips rather than editing an inert slot.
    pub fn paramValue(self: *const Slicer, id: u16) ?f32 {
        const slice_idx = id >> 4;
        const param: u8 = @intCast(id & 0x0F);
        if (slice_idx >= self.slice_count) return null;
        return pad_mod.paramValue(&self.slices[slice_idx], param);
    }

    // -----------------------------------------------------------------------
    // Pattern variants (control thread) - mirrors DrumMachine's bank exactly.

    /// Sync the live pattern back into its bank slot. Silently leaves the
    /// slot's stale data in place on allocation failure (rare OOM,
    /// non-fatal - same tolerance `DrumMachine.storeActiveVariant` takes).
    fn storeActiveVariant(self: *Slicer) void {
        const slot = &self.variants[self.variant];
        const fresh = dupeMidi(self.allocator, &self.midi) catch return;
        freeMidi(self.allocator, &slot.midi);
        slot.midi = fresh;
        slot.step_count = self.step_count;
        slot.steps_per_beat = self.steps_per_beat;
    }

    /// Replace the live pattern with `slot`'s data (control thread). Used to
    /// activate a bank variant, to paste a yanked pattern, and by undo's
    /// whole-state restore. Silently leaves the live pattern unchanged on
    /// allocation failure.
    pub fn applyVariant(self: *Slicer, slot: Variant) void {
        const want: u16 = std.math.clamp(slot.step_count, 1, max_steps);
        // A never-materialized bank slot (rows still `&.{}`) means "a blank
        // pattern of that length", not "zero-length rows": every step
        // accessor indexes `midi[slice][step]` for `step < step_count`, so
        // the rows have to actually be that long.
        const fresh = (if (slot.midi[0].len == 0)
            allocMidi(self.allocator, want)
        else
            dupeMidi(self.allocator, &slot.midi)) catch return;
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        freeMidi(self.allocator, &self.midi);
        self.midi = fresh;
        self.step_count = @intCast(fresh[0].len);
        self.steps_per_beat = std.math.clamp(slot.steps_per_beat, 1, 32);
        self.sample_lock.unlock();
    }

    /// Switch the active variant to `v`, saving the live pattern first.
    pub fn selectVariant(self: *Slicer, v: u8) void {
        if (v >= self.variant_count or v == self.variant) return;
        self.storeActiveVariant();
        self.variant = v;
        self.applyVariant(self.variants[v]);
    }

    /// Step the active variant by `delta`, wrapping within the bank.
    pub fn cycleVariant(self: *Slicer, delta: i32) void {
        const n: i32 = self.variant_count;
        if (n <= 1) return;
        self.selectVariant(@intCast(@mod(@as(i32, self.variant) + delta, n)));
    }

    /// Duplicate the active variant into a new slot and switch to it - the
    /// live pattern already matches the copy. False when the bank is full or
    /// the copy can't be allocated.
    pub fn addVariant(self: *Slicer) bool {
        if (self.variant_count >= max_variants) return false;
        self.storeActiveVariant();
        const fresh = dupeMidi(self.allocator, &self.variants[self.variant].midi) catch return false;
        self.variants[self.variant_count] = .{
            .midi = fresh,
            .step_count = self.step_count,
            .steps_per_beat = self.steps_per_beat,
        };
        self.variant = self.variant_count;
        self.variant_count += 1;
        return true;
    }

    /// Remove the active variant, shifting later slots down. The slot that
    /// takes its index (or the new last) becomes active. False when it's the
    /// only one left.
    ///
    /// The shift moves ownership of each row: the removed slot's own rows are
    /// freed first, and the vacated tail slot is left aliasing the pointer it
    /// was moved from - which is why every mutator here iterates
    /// `0..variant_count` and never past it (same rule as DrumMachine's).
    pub fn removeVariant(self: *Slicer) bool {
        if (self.variant_count <= 1) return false;
        freeMidi(self.allocator, &self.variants[self.variant].midi);
        var i = self.variant;
        while (i + 1 < self.variant_count) : (i += 1) self.variants[i] = self.variants[i + 1];
        self.variant_count -= 1;
        if (self.variant >= self.variant_count) self.variant = self.variant_count - 1;
        self.applyVariant(self.variants[self.variant]);
        return true;
    }

    /// Variant `v`'s pattern data. The active one is read from the live rows
    /// (its bank slot is stale until the next switch). The returned rows
    /// ALIAS this slicer's storage - copy them with `dupeMidi` before
    /// keeping them past the next edit, same contract DrumMachine's has.
    pub fn variantData(self: *const Slicer, v: u8) Variant {
        if (v == self.variant) {
            return .{
                .midi = self.midi,
                .step_count = self.step_count,
                .steps_per_beat = self.steps_per_beat,
            };
        }
        return self.variants[@min(v, max_variants - 1)];
    }

    /// Display letter for variant `v`: A, B, C, …
    pub fn variantLetter(v: u8) u8 {
        return 'A' + @as(u8, @min(v, max_variants - 1));
    }

    /// Step slice `slice`'s choke group forward: none → 1 → … → max → none.
    pub fn cycleChokeGroup(self: *Slicer, slice: u8) void {
        if (slice >= max_slices) return;
        self.choke_group[slice] = (self.choke_group[slice] + 1) % (max_choke_groups + 1);
    }

    // -----------------------------------------------------------------------
    // Song-mode clip timeline (mirrors DrumMachine's)

    /// Replace the song-mode clip timeline (control thread). Takes ownership
    /// of every clip's `midi` rows - build them fresh per call (e.g. via
    /// `dupeMidi`) and don't free or reuse them afterward. Taken under
    /// `sample_lock` - `processBlock` holds it for the whole block, so
    /// `fireSongStep` never reads a half-written list.
    pub fn setSongClips(self: *Slicer, clips: []const SongClip, length_steps: u32, steps_per_beat: u8) void {
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        for (self.song_clips[0..self.song_clip_count]) |*old| freeMidi(self.allocator, &old.midi);
        const count = @min(clips.len, @as(usize, max_song_clips));
        for (clips[0..count], self.song_clips[0..count]) |src, *dst| dst.* = src;
        self.song_clip_count = @intCast(count);
        self.song_length_steps = length_steps;
        self.song_steps_per_beat = std.math.clamp(steps_per_beat, 1, 32);
    }

    // -----------------------------------------------------------------------
    // Step grid (control thread edits; audio thread reads in processBlock).
    // Every accessor below mirrors `DrumMachine`'s of the same name, over the
    // same `MidiNote` payload - see that file for the per-field rationale.

    pub fn toggleStep(self: *Slicer, slice: u8, step: u16) void {
        if (slice >= max_slices or step >= self.step_count) return;
        self.midi[slice][step] = if (self.midi[slice][step] == null)
            gridNote(slice, step, vel_full)
        else
            null;
    }

    pub fn stepActive(self: *const Slicer, slice: u8, step: u16) bool {
        if (slice >= max_slices or step >= self.step_count) return false;
        return self.midi[slice][step] != null;
    }

    pub fn stepVel(self: *const Slicer, slice: u8, step: u16) u8 {
        if (slice >= max_slices or step >= self.step_count) return vel_full;
        const note = self.midi[slice][step] orelse return vel_full;
        return note.velocity;
    }

    pub fn setStepVel(self: *Slicer, slice: u8, step: u16, level: u8) void {
        if (slice >= max_slices or step >= self.step_count) return;
        if (self.midi[slice][step]) |*note| note.velocity = @intCast(@min(level, vel_full));
    }

    /// Step one step's velocity through the named preset bands - same
    /// single-key gesture as `DrumMachine.cycleStepVel`.
    pub fn cycleStepVel(self: *Slicer, slice: u8, step: u16) void {
        const cur = self.stepVel(slice, step);
        var idx: usize = vel_presets.len - 1; // not a preset value -> next lands on preset[0]
        for (vel_presets, 0..) |v, i| {
            // zig fmt: off
            if (v == cur) { idx = i; break; }
            // zig fmt: on
        }
        self.setStepVel(slice, step, vel_presets[(idx + 1) % vel_presets.len]);
    }

    /// Nudge one step's velocity by `delta`, clamped to 1..127 - 0 would be
    /// silent; use x to remove a step instead of zeroing its velocity.
    pub fn nudgeStepVel(self: *Slicer, slice: u8, step: u16, delta: i32) void {
        const cur: i32 = self.stepVel(slice, step);
        const next = std.math.clamp(cur + delta, 1, 127);
        self.setStepVel(slice, step, @intCast(next));
    }

    /// Fire chance of the step in percent; 100 on an empty step.
    pub fn stepProb(self: *const Slicer, slice: u8, step: u16) u8 {
        if (slice >= max_slices or step >= self.step_count) return 100;
        const note = self.midi[slice][step] orelse return 100;
        return note.prob;
    }

    pub fn setStepProb(self: *Slicer, slice: u8, step: u16, percent: i32) void {
        if (slice >= max_slices or step >= self.step_count) return;
        if (self.midi[slice][step]) |*note| note.prob = @intCast(std.math.clamp(percent, 0, 100));
    }

    pub fn cycleStepProb(self: *Slicer, slice: u8, step: u16) void {
        if (slice >= max_slices or step >= self.step_count) return;
        const note = if (self.midi[slice][step]) |*n| n else return;
        for (prob_presets, 0..) |p, i| {
            if (note.prob == p) {
                note.prob = prob_presets[(i + 1) % prob_presets.len];
                return;
            }
        }
        note.prob = prob_presets[0];
    }

    /// Timing offset as a percent of one step; 0 on an empty step.
    pub fn stepMicro(self: *const Slicer, slice: u8, step: u16) i8 {
        if (slice >= max_slices or step >= self.step_count) return 0;
        const note = self.midi[slice][step] orelse return 0;
        return note.micro;
    }

    pub fn setStepMicro(self: *Slicer, slice: u8, step: u16, pct: i32) void {
        if (slice >= max_slices or step >= self.step_count) return;
        if (self.midi[slice][step]) |*note| note.micro = @intCast(std.math.clamp(pct, -50, 50));
    }

    pub fn nudgeStepMicro(self: *Slicer, slice: u8, step: u16, delta: i32) void {
        self.setStepMicro(slice, step, @as(i32, self.stepMicro(slice, step)) + delta);
    }

    /// Hits packed into this step; 0/1 is a plain single hit.
    pub fn stepRetrig(self: *const Slicer, slice: u8, step: u16) u8 {
        if (slice >= max_slices or step >= self.step_count) return 0;
        const note = self.midi[slice][step] orelse return 0;
        return note.retrig;
    }

    pub fn setStepRetrig(self: *Slicer, slice: u8, step: u16, hits: i32) void {
        if (slice >= max_slices or step >= self.step_count) return;
        if (self.midi[slice][step]) |*note| note.retrig = @intCast(std.math.clamp(hits, 0, 8));
    }

    pub fn cycleStepRetrig(self: *Slicer, slice: u8, step: u16) void {
        if (slice >= max_slices or step >= self.step_count) return;
        const note = if (self.midi[slice][step]) |*n| n else return;
        for (retrig_presets, 0..) |r, i| {
            if (note.retrig == r) {
                note.retrig = retrig_presets[(i + 1) % retrig_presets.len];
                return;
            }
        }
        note.retrig = retrig_presets[0];
    }

    /// Trig condition of the step; `always` on an empty step.
    pub fn stepCond(self: *const Slicer, slice: u8, step: u16) Cond {
        if (slice >= max_slices or step >= self.step_count) return .always;
        const note = self.midi[slice][step] orelse return .always;
        return note.cond;
    }

    pub fn setStepCond(self: *Slicer, slice: u8, step: u16, cond: Cond) void {
        if (slice >= max_slices or step >= self.step_count) return;
        if (self.midi[slice][step]) |*note| note.cond = cond;
    }

    pub fn cycleStepCond(self: *Slicer, slice: u8, step: u16, delta: i32) void {
        const tags = std.meta.tags(Cond);
        const cur = @intFromEnum(self.stepCond(slice, step));
        const n: i32 = @intCast(tags.len);
        const next = @mod(@as(i32, cur) + delta, n);
        self.setStepCond(slice, step, @enumFromInt(@as(u8, @intCast(next))));
    }

    /// Flip the fill switch every `fill`/`not_fill` condition reads, and
    /// report the new state.
    pub fn toggleFill(self: *Slicer) bool {
        const next = !self.fill_on.load(.monotonic);
        self.fill_on.store(next, .monotonic);
        return next;
    }

    /// Per-step transpose in semitones; 0 on an empty step.
    pub fn stepTune(self: *const Slicer, slice: u8, step: u16) i8 {
        if (slice >= max_slices or step >= self.step_count) return 0;
        const note = self.midi[slice][step] orelse return 0;
        return note.tune;
    }

    pub fn setStepTune(self: *Slicer, slice: u8, step: u16, semis: i32) void {
        if (slice >= max_slices or step >= self.step_count) return;
        if (self.midi[slice][step]) |*note| note.tune = @intCast(std.math.clamp(semis, -24, 24));
    }

    pub fn nudgeStepTune(self: *Slicer, slice: u8, step: u16, delta: i32) void {
        self.setStepTune(slice, step, @as(i32, self.stepTune(slice, step)) + delta);
    }

    /// Steps slice `s` actually loops over inside a `pattern_len`-long
    /// pattern: its own `slice_len` when that's set and fits, else the whole
    /// pattern. See `DrumMachine.padSteps`.
    pub fn sliceSteps(self: *const Slicer, s: u8, pattern_len: u16) u16 {
        if (s >= max_slices or pattern_len == 0) return @max(pattern_len, 1);
        const own = self.slice_len[s];
        if (own == 0 or own > pattern_len) return pattern_len;
        return @max(own, 1);
    }

    /// Set slice `s`'s own loop length; 0 (or anything past the pattern) goes
    /// back to following the pattern.
    pub fn setSliceLen(self: *Slicer, s: u8, len: u16) void {
        if (s >= max_slices) return;
        self.slice_len[s] = if (len >= self.step_count) 0 else len;
    }

    /// Nudge slice `s`'s loop length, treating "follows the pattern" as the
    /// full length so stepping down from it lands one below.
    pub fn nudgeSliceLen(self: *Slicer, s: u8, delta: i32) void {
        if (s >= max_slices) return;
        const cur: i32 = self.sliceSteps(s, self.step_count);
        self.setSliceLen(s, @intCast(std.math.clamp(cur + delta, 1, self.step_count)));
    }

    /// Wipe one slice's row: no steps at all.
    pub fn clearSlice(self: *Slicer, slice: u8) void {
        self.clearRow(slice);
    }

    /// Fill one slice's row with full-velocity steps across the active length.
    pub fn fillSlice(self: *Slicer, slice: u8) void {
        if (slice >= max_slices) return;
        for (self.midi[slice], 0..) |*cell, step| cell.* = gridNote(slice, @intCast(step), vel_full);
    }

    /// Resize the live pattern to `n` steps, clamped to `[1, max_steps]`.
    /// Existing notes up to `min(old, new)` survive; a shrink then regrow does
    /// not resurrect anything past the new count. Silently leaves the pattern
    /// unchanged on allocation failure - a user-triggered, rare-OOM control
    /// thread action, not a hot path. Mirrors `DrumMachine.setStepCount`.
    pub fn setStepCount(self: *Slicer, n: u16) void {
        const new_count = std.math.clamp(n, 1, max_steps);
        if (new_count == self.step_count) return;
        var next = allocMidi(self.allocator, new_count) catch return;
        const keep = @min(self.step_count, new_count);
        for (0..max_slices) |slice| @memcpy(next[slice][0..keep], self.midi[slice][0..keep]);

        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        freeMidi(self.allocator, &self.midi);
        self.midi = next;
        self.step_count = new_count;
        self.sample_lock.unlock();
    }

    /// Change the native grid without moving hits in musical time - refuses
    /// (leaving the pattern untouched) rather than ever dropping a hit. See
    /// `DrumMachine.setStepsPerBeatPreservingTime`, which this mirrors.
    pub fn setStepsPerBeatPreservingTime(self: *Slicer, new_spb: u8) bool {
        if (new_spb == self.steps_per_beat) return true;
        if (new_spb < 1 or new_spb > 32) return false;
        const old_spb = self.steps_per_beat;
        const new_count_u32: u32 = @intCast(@divTrunc(@as(u32, self.step_count) * new_spb, old_spb));
        if (new_count_u32 < 1 or new_count_u32 > max_steps) return false;
        const new_count: u16 = @intCast(new_count_u32);

        var next = allocMidi(self.allocator, new_count) catch return false;
        var committed = false;
        defer if (!committed) freeMidi(self.allocator, &next);

        for (0..max_slices) |slice| {
            for (self.midi[slice]) |maybe_note| {
                const note = maybe_note orelse continue;
                const mapped_u32: u32 = @intCast(@divTrunc(@as(u32, note.step) * new_spb + old_spb / 2, old_spb));
                if (mapped_u32 >= new_count) return false;
                const mapped: u16 = @intCast(mapped_u32);
                if (next[slice][mapped] != null) return false;
                const dur_u32: u32 = @intCast(@divTrunc(@as(u32, note.duration_steps) * new_spb + old_spb / 2, old_spb));
                var moved = note;
                moved.step = mapped;
                moved.duration_steps = @intCast(std.math.clamp(dur_u32, 1, max_steps));
                next[slice][mapped] = moved;
            }
        }

        // Rescaled with the steps, same as `DrumMachine.pad_len`: a slice's
        // own loop length is in steps, and the row's musical length has to
        // survive the zoom.
        var lens = self.slice_len;
        for (&lens) |*len| {
            if (len.* == 0) continue;
            const scaled: u32 = @divTrunc(@as(u32, len.*) * new_spb + old_spb / 2, old_spb);
            len.* = if (scaled == 0 or scaled >= new_count) 0 else @intCast(scaled);
        }

        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        freeMidi(self.allocator, &self.midi);
        self.midi = next;
        self.step_count = new_count;
        self.steps_per_beat = new_spb;
        self.slice_len = lens;
        self.sample_lock.unlock();
        committed = true;
        return true;
    }

    /// One slice's notes in beat-relative form - what a piano-roll style
    /// consumer (bounce, MIDI export) wants. Mirrors
    /// `DrumMachine.copyPadMidi`.
    pub fn copySliceMidi(self: *const Slicer, slice: u8, out: []Note) u16 {
        if (slice >= max_slices) return 0;
        var count: u16 = 0;
        for (self.midi[slice]) |maybe_note| {
            const note = maybe_note orelse continue;
            if (count >= out.len) break;
            out[count] = note.toPattern(self.steps_per_beat);
            count += 1;
        }
        return count;
    }

    pub fn currentStep(self: *const Slicer) u16 {
        return self.current_step.load(.monotonic);
    }

    /// Is slice `slice` sounding right now? For display only - read without
    /// taking `sample_lock`, the same race-tolerant convention every other
    /// UI-side read here uses (worst case the highlight is one block stale,
    /// never a crash: the pool is a fixed inline array).
    pub fn slicePlaying(self: *const Slicer, slice: u8) bool {
        if (slice >= self.slice_count) return false;
        for (self.voices[slice]) |sv| {
            if (sv.active) return true;
        }
        return false;
    }

    /// Nudge swing by `delta` percent, clamped to [swing_min, swing_max].
    pub fn adjustSwing(self: *Slicer, delta: f32) void {
        if (!std.math.isFinite(delta)) return;
        const s = std.math.clamp(self.swing.load(.monotonic) + delta, swing_min, swing_max);
        self.swing.store(s, .monotonic);
    }

    pub fn setSwing(self: *Slicer, pct: f32) void {
        if (!std.math.isFinite(pct)) return;
        self.swing.store(std.math.clamp(pct, swing_min, swing_max), .monotonic);
    }

    // -----------------------------------------------------------------------
    // Audio thread processing

    /// Trigger `slice` through its choke group: a nonzero group first cuts
    /// every ringing voice in the group INCLUDING this slice's own pool -
    /// grouped slices opt back into the classic drum-machine cut behavior
    /// that plain `triggerSlice` deliberately skips (put every slice in one
    /// group for the MPC "mono" chop feel, or pair just two for an
    /// open/closed-hat-style gate).
    pub fn chokeTrigger(self: *Slicer, slice: u8, vel: f32, block_start: u32) void {
        self.chokeTriggerTuned(slice, vel, block_start, 0, -1.0);
    }

    /// `chokeTrigger` plus a per-hit transpose (a step's parameter-locked
    /// `tune`), carried on the voice - see `pad.Voice.tune`. `hold` is how
    /// long a gated slice plays before releasing itself (`pad.Voice
    /// .hold_frames`); -1 waits for a note-off instead.
    pub fn chokeTriggerTuned(self: *Slicer, slice: u8, vel: f32, block_start: u32, tune: i8, hold: f64) void {
        if (slice >= self.slice_count) return;
        const group = self.choke_group[slice];
        if (group != 0) {
            for (0..self.slice_count) |i| {
                // zig fmt: off
                if (self.choke_group[i] == group) for (&self.voices[i]) |*sv| { sv.* = .{}; };
                // zig fmt: on
            }
        }
        self.triggerSliceTuned(slice, vel, block_start, tune, hold);
    }

    /// Trigger `slice` (0-based), stealing the oldest voice in its own small
    /// pool if all are busy. A `.one_shot` slice replayed while still ringing
    /// is allowed to overlap, matching the "manipulate chops live" workflow
    /// (stutters, rolls); a `.retrigger` slice - the chop default - cuts its
    /// own ring first, the drum-kit convention. Choke groups extend that cut
    /// across slices - see `chokeTrigger`.
    pub fn triggerSlice(self: *Slicer, slice: u8, vel: f32, block_start: u32) void {
        self.triggerSliceTuned(slice, vel, block_start, 0, -1.0);
    }

    /// `triggerSlice` with a per-hit transpose and gated hold - see
    /// `chokeTriggerTuned`.
    pub fn triggerSliceTuned(self: *Slicer, slice: u8, vel: f32, block_start: u32, tune: i8, hold: f64) void {
        if (slice >= self.slice_count) return;
        var pool = &self.voices[slice];
        // zig fmt: off
        if (pad_mod.playMode(&self.slices[slice]) == .retrigger) for (pool) |*sv| { sv.* = .{}; };
        // zig fmt: on
        var slot: usize = 0;
        var oldest_age: u64 = std.math.maxInt(u64);
        for (pool, 0..) |*sv, i| {
            // zig fmt: off
            if (!sv.active) { slot = i; break; }
            if (sv.age < oldest_age) { oldest_age = sv.age; slot = i; }
            // zig fmt: on
        }
        pool[slot] = .{
            .active = true,
            .age = self.next_age,
            .v = .{ .active = true, .played = 0, .block_start = block_start, .vel = vel, .tune = tune, .hold_frames = hold },
        };
        self.next_age +%= 1;
    }

    pub fn processBlock(self: *Slicer, buf: []Sample) void {
        const channels = 2;
        const frames: u32 = @intCast(buf.len / channels);
        const sr: f64 = @floatFromInt(self.sample_rate);

        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();

        if (self.transport.playing and self.slice_count > 0) {
            const pos_f = @as(f64, @floatFromInt(self.transport.position_frames));
            const fps = self.transport.framesPerStep(if (self.song_mode) self.song_steps_per_beat else self.steps_per_beat);
            const swing_pct = self.swing.load(.monotonic);
            var step_k = self.next_step_k;

            const expected = @as(f64, @floatFromInt(step_k)) * fps;
            const resync_steps: u8 = if (self.song_mode) @max(2, self.song_steps_per_beat / 2) else 2;
            if (@abs(expected - pos_f) > fps * @as(f64, @floatFromInt(resync_steps))) {
                step_k = @intFromFloat(@ceil(pos_f / fps));
            }

            // Every step that could still place a hit inside this block.
            // "Could" rather than "does": a step's own `micro` can pull a hit
            // up to half a step ahead of its boundary, so a step whose
            // boundary is still in the future has to be considered early. The
            // hits themselves are emitted by `drainRolls`. Same shape as
            // `DrumMachine.processBlock`'s scan.
            const max_early = fps * 0.5;
            while (true) {
                var fire_pos = @as(f64, @floatFromInt(step_k)) * fps;
                if (self.song_mode) {
                    const ticks_per_sixteenth = @max(@as(u8, 1), self.song_steps_per_beat / 4);
                    if (step_k % ticks_per_sixteenth == 0 and
                        (step_k / ticks_per_sixteenth) & 1 == 1)
                    {
                        fire_pos += fps * ticks_per_sixteenth *
                            @as(f64, swing_pct - 50.0) / 50.0;
                    }
                } else if (step_k & 1 == 1) {
                    fire_pos += fps * @as(f64, swing_pct - 50.0) / 50.0;
                }
                if (fire_pos - max_early >= pos_f + @as(f64, @floatFromInt(frames))) break;

                if (self.song_mode) {
                    self.fireSongStep(step_k, fire_pos, fps);
                } else {
                    // Each slice wraps at its own length (`slice_len`), so
                    // rows can run out of phase with each other; the UI
                    // playhead still follows the pattern's own length.
                    const fill_on = self.fill_on.load(.monotonic);
                    for (0..self.slice_count) |s| {
                        const len = self.sliceSteps(@intCast(s), self.step_count);
                        const idx: u16 = @intCast(step_k % len);
                        const note = self.midi[s][idx] orelse continue;
                        if (!trigFires(note, @intCast(s), step_k, step_k / len, fill_on)) continue;
                        self.scheduleNote(@intCast(s), note, fire_pos, fps);
                    }
                    self.current_step.store(@intCast(step_k % self.step_count), .monotonic);
                }
                step_k += 1;
            }

            self.next_step_k = step_k;
            // After the step scan, so a roll started by a step in this very
            // block still gets its tail hits considered here.
            self.drainRolls(pos_f, frames);
        }

        for (self.slices[0..self.slice_count], self.voices[0..self.slice_count]) |*pad, *pool| {
            for (pool) |*sv| {
                if (!sv.active) continue;
                // Keep a mid-block trigger's `block_start` offset for its
                // first render - renderVoice consumes and resets it - same
                // rule as Sampler.processBlock (see its comment there).
                pad_mod.renderVoice(&sv.v, pad, buf, channels, frames, sr);
                if (!sv.v.active) sv.active = false;
            }
        }
    }

    /// Fire slices for absolute step `step_k` from the song timeline. Past
    /// `song_length_steps` this goes silent instead of wrapping - the
    /// arrangement plays once through, not on a loop. Mirrors
    /// `DrumMachine.fireSongStep`; caller (processBlock) holds sample_lock.
    fn fireSongStep(self: *Slicer, step_k: u64, fire_pos: f64, tick_frames: f64) void {
        if (self.song_length_steps == 0 or step_k >= self.song_length_steps) return;
        const lk: u32 = @intCast(step_k);
        for (self.song_clips[0..self.song_clip_count]) |*clip| {
            if (lk < clip.start_step or lk >= clip.start_step + clip.span_steps) continue;
            if (clip.step_count == 0) return;
            const elapsed = lk - clip.start_step;
            const scaled = elapsed * clip.steps_per_beat;
            if (scaled % self.song_steps_per_beat != 0) continue;
            const local: u32 = scaled / self.song_steps_per_beat;
            const fill_on = self.fill_on.load(.monotonic);
            // The song timeline ticks finer than the clip's own grid, so a
            // roll has to be spaced across a *clip* step, not a song tick.
            const step_frames = tick_frames *
                @as(f64, @floatFromInt(self.song_steps_per_beat)) /
                @as(f64, @floatFromInt(@max(clip.steps_per_beat, 1)));
            for (0..self.slice_count) |s| {
                const len = self.sliceSteps(@intCast(s), clip.step_count);
                const idx: u16 = @intCast(local % len);
                const note = clip.midi[s][idx] orelse continue;
                if (!trigFires(note, @intCast(s), step_k, local / len, fill_on)) continue;
                self.scheduleNote(@intCast(s), note, fire_pos, step_frames);
            }
            self.current_step.store(@intCast(local % clip.step_count), .monotonic);
            return; // clips never overlap
        }
        // No clip under the playhead: keep the UI step indicator moving
        // through the gap instead of freezing on the last clip's step.
        self.current_step.store(@intCast(lk % self.step_count), .monotonic);
    }

    /// Does `note` fire on this pass? Probability and condition are ANDed,
    /// Elektron-style - see `DrumMachine.trigFires`, which this mirrors (and
    /// whose `Cond` this shares).
    fn trigFires(note: MidiNote, slice: u8, step_k: u64, pass: u64, fill_on: bool) bool {
        if (!note.cond.holds(pass, fill_on)) return false;
        if (note.prob >= 100) return true;
        if (note.prob == 0) return false;
        return rollPercent(step_k, slice) < note.prob;
    }

    /// A 0-99 roll from the absolute step and the slice - stateless on the
    /// audio thread, and the same stretch of transport rolls the same way
    /// twice. See `DrumMachine.rollPercent`.
    fn rollPercent(step_k: u64, slice: u8) u8 {
        var z: u64 = step_k *% 0x9E3779B97F4A7C15 +% (@as(u64, slice) *% 0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        z ^= z >> 31;
        return @intCast(z % 100);
    }

    /// Schedule `note` on slice `s`. `step_pos` is its step's absolute
    /// transport position; `micro` shifts the hit off that, and a roll spreads
    /// further hits across the step's own `step_frames`. Nothing is emitted
    /// here - `drainRolls` does that once the hits' real positions land inside
    /// a block, which is what lets a hit sit before its own step boundary or
    /// after the block that scheduled it.
    fn scheduleNote(self: *Slicer, s: u8, note: MidiNote, step_pos: f64, step_frames: f64) void {
        const offset = step_frames * @as(f64, @floatFromInt(note.micro)) / 100.0;
        const hits: u8 = @max(note.retrig, 1);
        const interval = if (hits > 1 and step_frames > 0.0)
            step_frames / @as(f64, @floatFromInt(hits))
        else
            0.0;
        // A gated slice stops where its step does (a roll's hits stop where
        // the next one starts) instead of ringing over the steps after it -
        // the whole point of chopping. A latched one-shot ignores this and
        // plays its region out; see `pad.Voice.hold_frames`.
        self.rolls[s] = .{
            .remaining = hits,
            .next_pos = step_pos + offset,
            .interval = interval,
            .vel = velGain(note.velocity),
            .tune = note.tune,
            .hold = if (interval > 0.0) interval else step_frames * @as(f64, @floatFromInt(@max(note.duration_steps, 1))),
        };
    }

    /// Emit every scheduled hit landing in `[pos_f, pos_f + frames)` - see
    /// `DrumMachine.drainRolls` for the clamp/drop rules this mirrors.
    fn drainRolls(self: *Slicer, pos_f: f64, frames: u32) void {
        const frames_f: f64 = @floatFromInt(frames);
        const block_end = pos_f + frames_f;
        for (&self.rolls, 0..) |*slot, s| {
            const roll = if (slot.*) |*r| r else continue;
            while (roll.remaining > 0 and roll.next_pos < block_end) {
                if (roll.next_pos >= pos_f - frames_f) {
                    const off: u32 = if (roll.next_pos <= pos_f) 0 else @intCast(@min(
                        @as(u64, @intFromFloat(roll.next_pos - pos_f)),
                        @as(u64, frames - 1),
                    ));
                    self.chokeTriggerTuned(@intCast(s), roll.vel, off, roll.tune, roll.hold);
                }
                roll.remaining -= 1;
                // A single hit has no interval to advance by; bail rather than
                // spinning on next_pos += 0.
                if (roll.remaining == 0 or roll.interval <= 0.0) {
                    roll.remaining = 0;
                    break;
                }
                roll.next_pos += roll.interval;
            }
            if (roll.remaining == 0) slot.* = null;
        }
    }

    pub fn resetAll(self: *Slicer) void {
        self.clearVoices();
        // Drop any roll tail with the voices it would have fed - a stop or a
        // panic must not leave hits scheduled past it.
        self.rolls = [_]?Roll{null} ** max_slices;
    }

    /// `deviceOf`'s expected name; forwards to `resetAll`.
    pub fn reset(self: *Slicer) void {
        self.resetAll();
    }

    pub fn handleEvent(self: *Slicer, ev: dsp.Event) void {
        switch (ev) {
            // A qwerty/MIDI note maps onto a slice by index, wrapping modulo
            // the current slice count - same convention DrumMachine.
            // triggerPad's `note % max_pads` uses for pad triggering.
            .note_on => |e| if (self.slice_count > 0) {
                self.chokeTrigger(e.note % self.slice_count, e.velocity, 0);
            },
            // Only a gated slice (`Pad.gate`) acts on the release; the
            // default latched slice plays out regardless.
            .note_off => |e| if (self.slice_count > 0) {
                var oldest: ?*SliceVoice = null;
                for (&self.voices[e.note % self.slice_count]) |*sv| {
                    if (!sv.active or sv.v.release_frames >= 0.0) continue;
                    if (oldest == null or sv.age < oldest.?.age) oldest = sv;
                }
                if (oldest) |sv| pad_mod.release(&sv.v);
            },
            .set_param => |e| self.adjustParam(e.id, e.steps),
            .set_param_abs => |e| self.setParamAbsolute(e.id, e.value),
            .cc, .pitch_bend, .automation_param, .clap_param, .vst3_param, .set_sidechain_buf, .capture_pad => {},
            .all_off => self.resetAll(),
        }
    }
};

/// Energy-envelope onset detection for `chopTransients`: fills `out` with
/// ascending slice-start positions (fractions of the clip, `out[0]` always
/// 0.0) and returns how many were found (>= 1). An onset is a 10 ms RMS hop
/// that rises `ratio`x above the recent local average - `sensitivity` 1..9
/// maps to ratio 3.7 (only the hardest hits) down to 1.3 (every flutter) -
/// gated by a noise floor relative to the clip's own peak and a 40 ms
/// refractory so one drum hit can't chop twice. The boundary lands one hop
/// early so the attack transient stays inside its own slice.
pub fn detectOnsets(samples: []const f32, sample_rate: u32, sensitivity: u8, out: *[Slicer.max_slices]f32) u8 {
    out[0] = 0.0;
    var count: u8 = 1;
    if (samples.len == 0) return count;

    const hop: usize = @max(sample_rate / 100, 32);
    const hops = samples.len / hop;
    if (hops < 4) return count;

    const hopRms = struct {
        fn f(s: []const f32, h: usize, size: usize) f32 {
            var acc: f32 = 0;
            for (s[h * size ..][0..size]) |x| acc += x * x;
            return @sqrt(acc / @as(f32, @floatFromInt(size)));
        }
    }.f;

    var peak_env: f32 = 1e-9;
    for (0..hops) |h| peak_env = @max(peak_env, hopRms(samples, h, hop));
    const noise_floor = peak_env * 0.04;

    const s = std.math.clamp(sensitivity, 1, 9);
    const ratio = 3.7 - 0.3 * @as(f32, @floatFromInt(s - 1));
    const min_gap_hops: usize = 4; // 40 ms refractory

    // Moving local average over the last `ring.len` hops, seeded with the
    // first hop so a hot open doesn't divide by a zero-energy history.
    var ring = [_]f32{hopRms(samples, 0, hop)} ** 8;
    var ring_i: usize = 0;
    var prev_env = ring[0];
    var last_onset_hop: usize = 0;

    for (1..hops) |h| {
        const env = hopRms(samples, h, hop);
        var avg: f32 = 0;
        for (ring) |r| avg += r;
        avg /= @floatFromInt(ring.len);

        const rising = env > prev_env;
        const loud_enough = env > noise_floor;
        const jumps = env > avg * ratio;
        const spaced = h - last_onset_hop >= min_gap_hops;
        if (rising and loud_enough and jumps and spaced) {
            last_onset_hop = h;
            const pos = @as(f32, @floatFromInt((h - 1) * hop)) / @as(f32, @floatFromInt(samples.len));
            // The head is always slice 0; an onset this close to it is it.
            if (pos > 0.02 and count < Slicer.max_slices) {
                out[count] = pos;
                count += 1;
            }
        }

        ring[ring_i] = env;
        ring_i = (ring_i + 1) % ring.len;
        prev_env = env;
    }
    return count;
}

// ---------------------------------------------------------------------------
// Tests

fn installTestClip(s: *Slicer) !void {
    s.allocator.free(s.samples);
    s.samples = try s.allocator.alloc(f32, 1024);
    @memset(s.samples, 0.5);
    for (&s.slices) |*p| p.samples = s.samples;
}

test "slicer starts with no sample" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();

    try std.testing.expectEqual(@as(usize, 0), s.samples.len);
    try std.testing.expectEqualStrings("", s.clipName());
    try std.testing.expectEqual(@as(u8, 0), s.slice_count);
}

test "swing setters ignore non-finite values" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.setSwing(62.0);
    s.setSwing(std.math.nan(f32));
    try std.testing.expectEqual(@as(f32, 62.0), s.swing.load(.monotonic));
    s.setSwing(std.math.inf(f32));
    try std.testing.expectEqual(@as(f32, 62.0), s.swing.load(.monotonic));
    s.adjustSwing(std.math.nan(f32));
    try std.testing.expectEqual(@as(f32, 62.0), s.swing.load(.monotonic));
}

test "sliceInto equal-divides the clip and clamps out-of-range counts" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();

    s.sliceInto(4);
    try std.testing.expectEqual(@as(u8, 4), s.slice_count);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.slices[0].start_norm, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), s.slices[0].end_norm, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), s.slices[3].start_norm, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.slices[3].end_norm, 1e-6);
    for (s.slices[0..4]) |slice| try std.testing.expectEqual(pad_mod.PlayMode.retrigger, pad_mod.playMode(&slice));

    s.sliceInto(0); // clamps up to 1
    try std.testing.expectEqual(@as(u8, 1), s.slice_count);
    s.sliceInto(200); // clamps down to max_slices
    try std.testing.expectEqual(Slicer.max_slices, s.slice_count);
}

test "chopAt normalizes non-finite and descending boundaries" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();

    s.chopAt(&.{ 0.0, 0.75, std.math.nan(f32), 0.25, std.math.inf(f32) });
    try std.testing.expectEqual(@as(u8, 5), s.slice_count);
    var previous: f32 = 0.0;
    for (s.slices[0..s.slice_count]) |slice| {
        try std.testing.expect(std.math.isFinite(slice.start_norm));
        try std.testing.expect(std.math.isFinite(slice.end_norm));
        try std.testing.expect(slice.start_norm >= previous);
        try std.testing.expect(slice.end_norm >= slice.start_norm);
        previous = slice.end_norm;
    }
    try std.testing.expectEqual(@as(f32, 1.0), previous);
    for (s.slices[0..s.slice_count]) |slice| try std.testing.expectEqual(pad_mod.PlayMode.retrigger, pad_mod.playMode(&slice));
}

test "every slice aliases the same underlying buffer (no duplication)" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(8);
    for (s.slices[0..8]) |slice| {
        try std.testing.expectEqual(s.samples.ptr, slice.samples.ptr);
    }
}

test "re-slicing clears voices tied to the old regions" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(2);
    s.triggerSlice(1, 1.0, 0);
    try std.testing.expect(s.voices[1][0].active);

    s.sliceInto(4);
    for (s.voices) |pool| {
        for (pool) |voice| try std.testing.expect(!voice.active);
    }
}

test "triggerSlice renders only within its own region" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    try installTestClip(&s);
    s.sliceInto(2);
    s.triggerSlice(1, 1.0, 0);

    var buf: [512]Sample = undefined;
    @memset(&buf, 0.0);
    s.processBlock(&buf);
    var peak: f32 = 0;
    for (buf) |x| peak = @max(peak, @abs(x));
    try std.testing.expect(peak > 0.001);

    // Slice 1's Voice.played must never exceed its own region length.
    try std.testing.expect(s.voices[1][0].v.played <= @as(f64, @floatFromInt(s.samples.len)) / 2.0 + 1.0);
}

test "triggerSlice past slice_count is a no-op" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(2);
    s.triggerSlice(5, 1.0, 0);
    try std.testing.expect(!s.voices[5][0].active);
}

test "step sequencer fires the right slice on schedule" {
    var transport = Transport{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    transport.play();
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    try installTestClip(&s);
    s.sliceInto(4);
    s.toggleStep(2, 0); // slice 2 fires on step 0
    s.setStepCount(16);

    var buf: [64]Sample = undefined;
    @memset(&buf, 0.0);
    s.processBlock(&buf);
    try std.testing.expect(s.voices[2][0].active);
    try std.testing.expect(!s.voices[0][0].active);
}

test "note_on wraps a note onto a slice by index" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(4);
    s.device().sendEvent(.{ .note_on = .{ .note = 5, .velocity = 1.0 } }); // 5 % 4 = 1
    try std.testing.expect(s.voices[1][0].active);
}

test "adjustParam edits the addressed slice only" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(4);
    s.adjustParam(Slicer.paramId(2, 7), 10); // slice 2's gain +10 steps of 0.01
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), s.slices[2].gain, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.slices[0].gain, 1e-4);
}

/// Four decaying noise bursts at 0/25/50/75% of a one-second clip -
/// a synthetic drum loop for the transient-chop tests.
fn burstClip(allocator: std.mem.Allocator, sample_rate: u32) ![]f32 {
    const len = sample_rate;
    const out = try allocator.alloc(f32, len);
    @memset(out, 0.0);
    var rng = std.Random.DefaultPrng.init(42);
    const burst_len = sample_rate / 20; // 50 ms
    for (0..4) |b| {
        const at = b * (len / 4);
        for (0..burst_len) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(burst_len));
            out[at + i] = (rng.random().float(f32) * 2.0 - 1.0) * (1.0 - t);
        }
    }
    return out;
}

test "chopTransients finds the bursts and anchors slice 0 at the head" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    std.testing.allocator.free(s.samples);
    s.samples = try burstClip(std.testing.allocator, 48_000);
    for (&s.slices) |*p| p.samples = s.samples;

    const n = s.chopTransients(5);
    try std.testing.expectEqual(@as(u8, 4), n);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.slices[0].start_norm, 1e-6);
    // Each detected boundary sits within 3% of its burst (one hop early).
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), s.slices[1].start_norm, 0.03);
    try std.testing.expectApproxEqAbs(@as(f32, 0.50), s.slices[2].start_norm, 0.03);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), s.slices[3].start_norm, 0.03);
    // Contiguous: each slice ends where the next begins.
    try std.testing.expectApproxEqAbs(s.slices[1].start_norm, s.slices[0].end_norm, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.slices[3].end_norm, 1e-6);
}

test "chopTransients on silence falls back to one whole-clip slice" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    std.testing.allocator.free(s.samples);
    s.samples = try std.testing.allocator.alloc(f32, 48_000);
    @memset(s.samples, 0.0);
    for (&s.slices) |*p| p.samples = s.samples;

    try std.testing.expectEqual(@as(u8, 1), s.chopTransients(9));
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.slices[0].start_norm, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.slices[0].end_norm, 1e-6);
}

test "chopRandom lays down n contiguous, uneven, non-empty slices" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    try std.testing.expectEqual(@as(u8, 12), s.chopRandom(12, prng.random()));

    var even = true;
    const nominal: f32 = 1.0 / 12.0;
    for (0..12) |i| {
        const p = &s.slices[i];
        // Non-empty, contiguous, and inside the clip.
        try std.testing.expect(p.end_norm > p.start_norm);
        if (i == 0) try std.testing.expectApproxEqAbs(@as(f32, 0.0), p.start_norm, 1e-6);
        if (i == 11) try std.testing.expectApproxEqAbs(@as(f32, 1.0), p.end_norm, 1e-6);
        if (i + 1 < 12) try std.testing.expectApproxEqAbs(p.end_norm, s.slices[i + 1].start_norm, 1e-6);
        if (@abs((p.end_norm - p.start_norm) - nominal) > 1e-4) even = false;
    }
    // The whole point of the dice roll: not an even divide.
    try std.testing.expect(!even);

    // Degenerate counts still leave a usable chop.
    try std.testing.expectEqual(@as(u8, 1), s.chopRandom(1, prng.random()));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.slices[0].end_norm, 1e-6);
}

test "cycleModeAll resolves mixed slices and walks all three play modes" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(3);
    // A fresh chop is retrigger; knock one slice out of step to prove mixed
    // state still lands uniform.
    for (s.slices[0..3]) |slice| try std.testing.expectEqual(pad_mod.PlayMode.retrigger, pad_mod.playMode(&slice));
    pad_mod.setPlayMode(&s.slices[1], .gate);

    for ([_]pad_mod.PlayMode{ .one_shot, .gate, .retrigger }) |want| {
        try std.testing.expectEqual(want, s.cycleModeAll());
        for (s.slices[0..3]) |slice| try std.testing.expectEqual(want, pad_mod.playMode(&slice));
    }
}

test "a retrigger slice cuts its own ring, a one-shot overlaps" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(2);

    s.triggerSlice(0, 1.0, 0);
    s.triggerSlice(0, 1.0, 0);
    var live: usize = 0;
    for (s.voices[0]) |sv| {
        if (sv.active) live += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), live);

    pad_mod.setPlayMode(&s.slices[1], .one_shot);
    s.triggerSlice(1, 1.0, 0);
    s.triggerSlice(1, 1.0, 0);
    live = 0;
    for (s.voices[1]) |sv| {
        if (sv.active) live += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), live);
}

test "spreadPitch ramps a semitone step across the live slices only" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(4);

    s.spreadPitch(3.0);
    for (0..4) |i| {
        const want: f32 = 3.0 * @as(f32, @floatFromInt(i));
        try std.testing.expectApproxEqAbs(want, s.slices[i].pitch_semitones, 1e-6);
    }
    // Past the live count nothing was touched.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.slices[4].pitch_semitones, 1e-6);

    // A big step clamps at the pad pitch range rather than wrapping.
    s.spreadPitch(20.0);
    try std.testing.expectApproxEqAbs(@as(f32, 24.0), s.slices[3].pitch_semitones, 1e-6);
}

test "splitSlice halves the region and shifts later pattern rows down" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(3);
    s.toggleStep(2, 5); // will belong to slice 3 after the split
    s.slices[1].pitch_semitones = -12.0;

    try std.testing.expect(s.splitSlice(1));
    try std.testing.expectEqual(@as(u8, 4), s.slice_count);
    // Old slice 1 spanned 1/3..2/3; halves meet at 1/2.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s.slices[1].end_norm, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s.slices[2].start_norm, 1e-6);
    // The right half inherits params but starts silent.
    try std.testing.expectApproxEqAbs(@as(f32, -12.0), s.slices[2].pitch_semitones, 1e-6);
    try std.testing.expect(!s.stepActive(2, 5));
    // Old slice 2's programming followed it to row 3.
    try std.testing.expect(s.stepActive(3, 5));
}

test "mergeSliceRight ORs patterns and shifts later rows up" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(4);
    s.toggleStep(1, 0);
    s.setStepVel(1, 0, 40);
    s.toggleStep(2, 0);
    s.setStepVel(2, 0, 90);
    s.toggleStep(2, 7);
    s.toggleStep(3, 3);

    try std.testing.expect(s.mergeSliceRight(1));
    try std.testing.expectEqual(@as(u8, 3), s.slice_count);
    // Region 1 now spans old 1+2.
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), s.slices[1].start_norm, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), s.slices[1].end_norm, 1e-6);
    // Colliding step keeps the louder velocity; disjoint steps both survive.
    try std.testing.expect(s.stepActive(1, 0));
    try std.testing.expectEqual(@as(u8, 90), s.stepVel(1, 0));
    try std.testing.expect(s.stepActive(1, 7));
    // Old slice 3 shifted up to row 2.
    try std.testing.expect(s.stepActive(2, 3));
    try std.testing.expect(!s.mergeSliceRight(2)); // last slice: nothing to its right
}

test "mergeSliceRight rejects the maximum sentinel index" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(4);
    try std.testing.expect(!s.mergeSliceRight(std.math.maxInt(u8)));
}

test "setParamAbsolute/paramValue roundtrip, null past slice_count" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(2);
    s.setParamAbsolute(Slicer.paramId(1, 2), -7.0);
    try std.testing.expectApproxEqAbs(@as(f32, -7.0), s.paramValue(Slicer.paramId(1, 2)).?, 1e-6);
    s.setParamAbsolute(Slicer.paramId(1, 9), 1.0);
    try std.testing.expect(s.slices[1].reverse);
    try std.testing.expectEqual(@as(?f32, null), s.paramValue(Slicer.paramId(2, 0)));
}

test "cycleStepVel walks the preset ladder; nudge clamps at 1" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(1);
    // Velocity lives on the note, so an empty step has nothing to cycle - it
    // reads as full and stays there until a step is placed (same semantics as
    // the drum machine's).
    s.cycleStepVel(0, 0);
    try std.testing.expectEqual(@as(u8, 127), s.stepVel(0, 0));

    s.toggleStep(0, 0);
    try std.testing.expectEqual(@as(u8, 127), s.stepVel(0, 0));
    s.cycleStepVel(0, 0);
    try std.testing.expectEqual(@as(u8, 95), s.stepVel(0, 0));
    s.nudgeStepVel(0, 0, -200);
    try std.testing.expectEqual(@as(u8, 1), s.stepVel(0, 0));
}

test "fillSlice/clearSlice cover exactly the active step range" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(2);
    s.setStepCount(12);
    s.fillSlice(0);
    try std.testing.expect(s.stepActive(0, 11));
    try std.testing.expect(!s.stepActive(0, 12));
    s.clearSlice(0);
    try std.testing.expect(!s.stepActive(0, 0));
}

test "variant bank: add copies, select round-trips, remove shifts" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(4);
    s.toggleStep(0, 0);
    s.setStepVel(0, 0, 90);

    try std.testing.expect(s.addVariant()); // B = copy of A, now active
    try std.testing.expectEqual(@as(u8, 1), s.variant);
    try std.testing.expect(s.stepActive(0, 0));
    s.toggleStep(0, 0); // B diverges: step off
    s.toggleStep(1, 2);

    s.selectVariant(0);
    try std.testing.expect(s.stepActive(0, 0)); // A intact
    try std.testing.expectEqual(@as(u8, 90), s.stepVel(0, 0));
    try std.testing.expect(!s.stepActive(1, 2));

    s.selectVariant(1);
    try std.testing.expect(!s.stepActive(0, 0)); // B's divergence held
    try std.testing.expect(s.stepActive(1, 2));

    try std.testing.expect(s.removeVariant()); // drop B, back on A
    try std.testing.expectEqual(@as(u8, 1), s.variant_count);
    try std.testing.expect(s.stepActive(0, 0));
    try std.testing.expect(!s.removeVariant()); // last one stays
}

test "chokeTrigger cuts grouped voices, leaves ungrouped ringing" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(4);
    s.choke_group[0] = 1;
    s.choke_group[1] = 1;
    // Slice 2 ungrouped, slice 3 in a different group.
    s.choke_group[3] = 2;

    s.chokeTrigger(1, 1.0, 0);
    s.chokeTrigger(2, 1.0, 0);
    s.chokeTrigger(3, 1.0, 0);
    try std.testing.expect(s.voices[1][0].active);

    s.chokeTrigger(0, 1.0, 0); // group 1: cuts slice 1, spares 2 and 3
    try std.testing.expect(s.voices[0][0].active);
    try std.testing.expect(!s.voices[1][0].active);
    try std.testing.expect(s.voices[2][0].active);
    try std.testing.expect(s.voices[3][0].active);

    // Grouped self-retrigger cuts its own previous voice (mono chop feel):
    // still exactly one active voice in slice 0's pool.
    s.chokeTrigger(0, 1.0, 0);
    var active: usize = 0;
    for (s.voices[0]) |sv| active += @intFromBool(sv.active);
    try std.testing.expectEqual(@as(usize, 1), active);
}

test "ungrouped retrigger still overlaps (choke stays opt-in)" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(2);
    pad_mod.setPlayMode(&s.slices[0], .one_shot);
    s.chokeTrigger(0, 1.0, 0);
    s.chokeTrigger(0, 1.0, 0);
    var active: usize = 0;
    for (s.voices[0]) |sv| active += @intFromBool(sv.active);
    try std.testing.expectEqual(@as(usize, 2), active);
}

test "note-off releases only oldest overlapping slice voice" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(2);
    pad_mod.setPlayMode(&s.slices[0], .gate);
    s.triggerSlice(0, 1.0, 0);
    s.triggerSlice(0, 1.0, 0);

    s.device().sendEvent(.{ .note_off = .{ .note = 0 } });
    try std.testing.expectEqual(@as(f64, 0.0), s.voices[0][0].v.release_frames);
    try std.testing.expect(s.voices[0][1].v.release_frames < 0.0);
    s.device().sendEvent(.{ .note_off = .{ .note = 0 } });
    try std.testing.expectEqual(@as(f64, 0.0), s.voices[0][1].v.release_frames);
}

test "a sequenced hit carries its step's length as the gated hold" {
    var transport = Transport{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    transport.play();
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    try installTestClip(&s);
    s.sliceInto(4);
    s.toggleStep(0, 0);

    var buf: [64]Sample = undefined;
    @memset(&buf, 0.0);
    s.processBlock(&buf);
    // 120 bpm at 4 steps per beat: 6000 frames a step, so a gated slice stops
    // there rather than ringing into the steps after it.
    try std.testing.expectApproxEqAbs(
        transport.framesPerStep(s.steps_per_beat),
        s.voices[0][0].v.hold_frames,
        1e-6,
    );

    // A live hit has no step to end at and waits for its note-off instead.
    s.chokeTrigger(1, 1.0, 0);
    try std.testing.expect(s.voices[1][0].v.hold_frames < 0.0);
}

test "song mode fires the clip covering the playhead, silent past the end" {
    var transport = Transport{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    transport.play();
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    try installTestClip(&s);
    s.sliceInto(4);
    // Live pattern has slice 0 on step 0 - must NOT fire in song mode.
    s.toggleStep(0, 0);

    // `setSongClips` takes ownership of each clip's rows, so both machines
    // below get their own freshly-allocated copy.
    var midi = try Slicer.allocMidi(std.testing.allocator, 16);
    midi[2][0] = Slicer.gridNote(2, 0, Slicer.vel_full); // slice 2 on the clip's step 0
    const clip: Slicer.SongClip = .{
        .start_step = 0,
        .span_steps = 16,
        .step_count = 16,
        .midi = midi,
    };
    s.setSongClips(&.{clip}, 16, 4);
    s.song_mode = true;

    var buf: [64]Sample = undefined;
    @memset(&buf, 0.0);
    s.processBlock(&buf);
    try std.testing.expect(s.voices[2][0].active);
    try std.testing.expect(!s.voices[0][0].active);

    // Past the song's end: nothing fires.
    var s2 = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s2.deinit();
    s2.sliceInto(4);
    var clip2 = clip;
    clip2.midi = try Slicer.dupeMidi(std.testing.allocator, &midi);
    s2.setSongClips(&.{clip2}, 16, 4);
    s2.song_mode = true;
    var t2 = Transport{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    t2.play();
    t2.position_frames = 48_000 * 60; // way past 16 steps
    s2.transport = &t2;
    @memset(&buf, 0.0);
    s2.processBlock(&buf);
    for (s2.voices[0..4]) |pool| {
        for (pool) |sv| try std.testing.expect(!sv.active);
    }
}

test "all_off clears every slice's voices" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(2);
    s.triggerSlice(0, 1.0, 0);
    s.triggerSlice(1, 1.0, 0);
    s.device().sendEvent(.all_off);
    try std.testing.expect(!s.voices[0][0].active);
    try std.testing.expect(!s.voices[1][0].active);
}

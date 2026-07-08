//! Step-sequenced multisampler — the drum machine instrument.
//!
//! Eight pads, each a full embedded `dsp.Sampler` (see sampler.zig): its own
//! clip, sample start/end trim, pitch (playback transpose), amplitude ADSR,
//! gain, pan, and reverse toggle. DrumMachine itself only adds the step
//! sequencer on top — sample loading, param edits, and voice rendering are
//! delegated straight to each pad's Sampler, so there is exactly one place
//! that owns that logic (shared with the standalone melodic Sampler track).
//! A step trigger is `pad.resetAll()` + `pad.trigger(...)`: the reset forces
//! single-voice "choke" behaviour (a retrigger cuts the previous hit, the
//! classic drum-machine convention) even though Sampler itself is polyphonic.
//!
//! A 64-step bitmask per pad stores the
//! pattern; each bit is a u64 atomic so the UI thread can flip bits safely
//! while the audio thread reads them.  A parallel per-step array holds each
//! step's velocity (0-127, MIDI-style; 127 = full) as its own atomic u8 — no
//! bit-packing needed since each step's value is read/written whole.  The
//! sequencer fires on
//! step boundaries derived from the transport, using a monotonic step
//! counter to avoid the double-fire and float-truncation bugs that arise
//! from recomputing the boundary position every block; MPC-style swing
//! (50–75%) delays each off-beat 16th within its 8th-note pair.
//!
//! Per-pad params are plain scalar fields read by the audio thread and
//! nudged on the audio thread (via the `set_param` device event, with the
//! pad index encoded in the high nibble of the id) — same race-free path
//! the synth editor uses.  The UI reads them for display without locking,
//! matching the synth editor's convention.
//!
//! Pads can also be assigned to a choke group (0 = none, 1..max_choke_groups):
//! triggering a pad silences every other pad sharing its group, the classic
//! closed/open-hihat behaviour. `choke_group` is a plain per-pad array (same
//! race-tolerant convention as `step_count` — control thread writes, audio
//! thread reads, no atomics) nudged only by the rare `cycleChokeGroup` key.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const Transport = @import("../transport.zig").Transport;
const pad_mod = @import("pad.zig");
const drum_kit = @import("drum_kit.zig");
const Sampler = @import("sampler.zig").Sampler;

const Sample = types.Sample;

/// The shipped 8-pad kit: WAVs embedded from src/assets/kit/ (rendered by the
/// `genkit` build tool from dsp/drum_kit.zig). `data` is raw WAV bytes decoded
/// at init; `gain` is the pad's default mixer level.
const KitSlot = struct { data: []const u8, name: []const u8, gain: f32 };
const default_kit = [_]KitSlot{
    .{ .data = @embedFile("../assets/kit/kick.wav"),  .name = "kick",  .gain = 1.00 },
    .{ .data = @embedFile("../assets/kit/snare.wav"), .name = "snare", .gain = 0.85 },
    .{ .data = @embedFile("../assets/kit/hihat.wav"), .name = "hihat", .gain = 0.50 },
    .{ .data = @embedFile("../assets/kit/open.wav"),  .name = "open",  .gain = 0.50 },
    .{ .data = @embedFile("../assets/kit/clap.wav"),  .name = "clap",  .gain = 0.70 },
    .{ .data = @embedFile("../assets/kit/tom1.wav"),  .name = "tom-1", .gain = 0.80 },
    .{ .data = @embedFile("../assets/kit/tom2.wav"),  .name = "tom-2", .gain = 0.80 },
    .{ .data = @embedFile("../assets/kit/rim.wav"),   .name = "rim",   .gain = 0.65 },
};

pub const DrumMachine = struct {
    pub const max_pads: u8 = 64;
    pub const max_steps: u8 = 64;
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

    /// Full-velocity value (127, MIDI-style max) — a fresh/toggled-on step's
    /// default.
    pub const vel_full: u8 = 127;

    /// Named preset bands `cycleStepVel`'s quick single-key gesture steps
    /// through: 127→95→63→31→127 (the same 100/75/25/25% feel the old 2-bit
    /// encoding had, just at the new resolution). Also doubles as the
    /// index-keyed remap `legacyVelToNew` uses for pre-v12 files, so an old
    /// file's 2-bit level plays back at effectively the same loudness.
    const vel_presets = [_]u8{ 127, 95, 63, 31 };

    /// Remap a pre-v12 file's 2-bit velocity level (0-3, see the old
    /// `vel_lo`/`vel_hi` bitplane encoding) onto the new 0-127 scale.
    pub fn legacyVelToNew(level: u2) u8 {
        return vel_presets[level];
    }

    /// Gain for a step's 0-127 velocity value (127 = full volume).
    pub fn velGain(level: u8) f32 {
        return @as(f32, @floatFromInt(level)) / @as(f32, @floatFromInt(vel_full));
    }

    /// One pattern variant: a bank slot for the step grid. The active variant
    /// lives in the atomic `pattern`/`step_count` fields; inactive ones rest
    /// here as plain data (control thread only).
    pub const Variant = struct {
        pattern: [max_pads]u64 = [_]u64{0} ** max_pads,
        /// Per-step velocity (0-127; 127 = full). v12 — replaces the old
        /// 2-bit `vel_lo`/`vel_hi` bitplanes (see persist.zig's version doc).
        vel: [max_pads][max_steps]u8 = [_][max_steps]u8{[_]u8{vel_full} ** max_steps} ** max_pads,
        step_count: u8 = 16,
    };

    /// A drum clip flattened onto the arrangement's step timeline. `pattern` is
    /// a plain snapshot of the source bitmask (no atomics — the audio thread
    /// reads it under `pad_lock`). The clip's own `step_count`-long pattern
    /// repeats to fill `span_steps` (its whole-bar length on the timeline).
    pub const SongClip = struct {
        start_step: u32,
        span_steps: u32,
        step_count: u8,
        pattern: [max_pads]u64,
        /// Per-step velocity, same encoding as the live grid.
        vel: [max_pads][max_steps]u8 = [_][max_steps]u8{[_]u8{vel_full} ** max_steps} ** max_pads,
    };
    /// Number of editable params per pad (see `adjustParam`).
    pub const pad_param_count: u8 = 10;
    /// Id-space stride per pad. `set_param` ids are `pad << 4 | param`, so the
    /// stride is a power of two and pad/param decode with shift + mask.
    /// u16: at max_pads=64, `63 << 4 | param` is 1008+, past what a u8 id
    /// could hold (this used to cap addressable pads at 15) — see
    /// dsp/device.zig's Event.set_param doc comment.
    pub const param_stride: u16 = 16;

    allocator: std.mem.Allocator,
    sample_rate: u32,
    transport: *const Transport,

    /// Up to 64 full Samplers, one per pad — lazily materialized. `null`
    /// means the pad has never had a sample loaded into it: no Sampler
    /// exists, no memory beyond the tag (a materialized Sampler carries a
    /// real audio buffer, ~115KB even for the generated default clip, which
    /// matters multiplied out to 64 pads if every unused slot paid it).
    /// Materializes on `loadPadWav`/`setPadSamples`; every accessor treats
    /// null as "silent, nothing to do" — same "no override" shape
    /// `AutomationCurve`'s null case already uses elsewhere. Each
    /// materialized pad guards its own clip buffer against concurrent reads
    /// (audio thread) and writes (control thread calling loadPadWav/
    /// setPadSamples at runtime) — see Sampler.pad_lock.
    pads: [max_pads]?Sampler,
    /// Guards `song_clips`/`song_clip_count`/`song_length_steps` against
    /// concurrent control-thread writes (setSongClips) while the audio
    /// thread reads them in fireSongStep.
    pad_lock: std.atomic.Mutex = .unlocked,
    /// Bitmask: bit k == 1 means step k is active. u64 for atomic compat
    /// (max_steps = 64, one bit per step).
    /// Always mirrors the active variant; edits land here and are synced back
    /// to `variants[variant]` when switching away.
    pattern: [max_pads]std.atomic.Value(u64),
    /// Per-step velocity (see `velGain`), one atomic u8 per step — no
    /// bit-packing needed since each step's value is read/written whole.
    /// Atomic for the same UI-edits-while-audio-reads reason as `pattern`.
    vel: [max_pads][max_steps]std.atomic.Value(u8),
    step_count: u8,
    /// Swing percent (see `swing_min`/`swing_max`): where the off-beat 16th
    /// sits within its 8th-note pair. UI writes, audio thread reads.
    swing: std.atomic.Value(f32) = .init(50.0),
    /// Per-pad choke group (0 = none). See `chokeTrigger`.
    choke_group: [max_pads]u8 = [_]u8{0} ** max_pads,

    // ── Pattern variants (control thread only) ──────────────────────────────
    /// Bank slots. Slot `variant` is stale while active — read it through
    /// `variantData`, which pulls the live atomics instead.
    variants: [max_variants]Variant = [_]Variant{.{}} ** max_variants,
    variant_count: u8 = 1,
    /// Index of the active variant (the one in the live `pattern`).
    variant: u8 = 0,

    // ── Song-mode playback (control thread writes, audio thread reads under
    //    pad_lock) ──────────────────────────────────────────────────────────
    /// When true, processBlock fires from `song_clips` under the playhead
    /// instead of the live `pattern`. Set via Session.setSongMode.
    song_mode: bool = false,
    /// The lane's clips placed on the arrangement's step timeline.
    song_clips: [max_song_clips]SongClip = undefined,
    song_clip_count: u16 = 0,
    /// Whole-arrangement length in steps; the song loops at this boundary.
    song_length_steps: u32 = 0,

    // Audio-thread-only state:
    /// Monotonic counter of steps that have fired. Resynced on seek.
    next_step_k: u64,

    /// Current step index, published by the audio thread for UI display.
    current_step: std.atomic.Value(u8),

    pub fn init(
        allocator: std.mem.Allocator,
        sample_rate: u32,
        transport: *const Transport,
    ) !DrumMachine {
        var self: DrumMachine = .{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .transport = transport,
            .pads = undefined,
            .pattern = undefined,
            .vel = undefined,
            .step_count = 32, // default 2 bars; user can extend to max_steps with >

            .next_step_k = 0,
            .current_step = .init(0),
        };
        for (&self.pads) |*p| p.* = null; // lazily materialized — see the field's doc comment
        for (&self.pattern) |*p| p.* = .init(0);
        for (&self.vel) |*row| for (row) |*p| { p.* = .init(vel_full); };

        // Load the shipped kit: WAVs rendered from dsp/drum_kit.zig by the
        // `genkit` build tool and embedded in the binary. Per-pad default gains
        // give a balanced out-of-the-box mix (the user can retune each in the
        // sampler editor). loadPadWav materializes pads 0..default_kit.len;
        // every pad past that stays null until the user loads something.
        for (default_kit, 0..) |slot, i| {
            try self.loadPadWav(@intCast(i), slot.data, slot.name);
            self.pads[i].?.pad.gain = slot.gain;
        }

        // Default kit pads 2/3 (hihat/open) share choke group 1 — the
        // classic pairing where an open hat ringing out gets cut by the
        // next closed-hat hit.
        self.choke_group[2] = 1;
        self.choke_group[3] = 1;

        // Default groove: 4-on-the-floor house pattern
        self.pattern[0].store(0x1111, .monotonic); // kick: every beat
        self.pattern[1].store((1 << 4) | (1 << 12), .monotonic); // snare: beats 2, 4
        self.pattern[2].store(0x5555, .monotonic); // hihat: every 8th note

        return self;
    }

    pub fn deinit(self: *DrumMachine) void {
        for (&self.pads) |*p| if (p.*) |*s| s.deinit();
    }

    /// Deep copy for track duplication: starts from a fresh `init` (which
    /// loads the embedded kit) so every buffer is uniquely allocated, then
    /// overwrites each pad with a dupe of this machine's actual clip audio
    /// (or leaves it null if the source pad was never loaded) and copies the
    /// pattern bank, step count, and swing. Song-mode state isn't carried —
    /// the caller rebuilds it from the arrangement if needed.
    pub fn dupe(self: *const DrumMachine) !DrumMachine {
        var out = try DrumMachine.init(self.allocator, self.sample_rate, self.transport);
        errdefer out.deinit();

        for (&out.pads, 0..) |*dst, i| {
            if (dst.*) |*d| d.deinit();
            dst.* = if (self.pads[i]) |*src| try src.dupe() else null;
        }
        for (&out.pattern, 0..) |*p, i| p.store(self.pattern[i].load(.acquire), .monotonic);
        for (&out.vel, &self.vel) |*dst_row, *src_row| {
            for (dst_row, src_row) |*dst, *src| dst.store(src.load(.acquire), .monotonic);
        }
        out.step_count = self.step_count;
        out.swing.store(self.swing.load(.monotonic), .monotonic);
        out.choke_group = self.choke_group;
        out.variants = self.variants;
        out.variant_count = self.variant_count;
        out.variant = self.variant;

        return out;
    }

    pub fn device(self: *DrumMachine) dsp.Device {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: dsp.Device.VTable = .{
        .process = processOpaque,
        .event = eventOpaque,
        .reset = resetOpaque,
    };

    // -----------------------------------------------------------------------
    // Pattern editing (UI thread)

    /// Bitmask covering steps 0..n — the valid bits for an n-step pattern.
    pub fn stepMask(n: u8) u64 {
        if (n >= 64) return ~@as(u64, 0);
        return (@as(u64, 1) << @intCast(n)) - 1;
    }

    pub fn setStepCount(self: *DrumMachine, n: u8) void {
        self.step_count = std.math.clamp(n, 1, max_steps);
        // Discard pattern bits beyond the new count — otherwise they'd
        // silently survive a shrink, reappear on grow, and be saved to disk.
        // Velocity gets the same hygiene: steps beyond the count reset to
        // full so a stray edit can't resurface invisibly on regrow either.
        const mask = stepMask(self.step_count);
        for (&self.pattern) |*p| _ = p.fetchAnd(mask, .acq_rel);
        for (&self.vel) |*row| {
            for (row[self.step_count..]) |*p| p.store(vel_full, .release);
        }
    }

    /// Nudge swing by `delta` percent, clamped to [swing_min, swing_max].
    /// Control thread; the audio thread picks it up next block.
    pub fn adjustSwing(self: *DrumMachine, delta: f32) void {
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

    /// Sync the live pattern back into its bank slot.
    fn storeActiveVariant(self: *DrumMachine) void {
        const slot = &self.variants[self.variant];
        for (&slot.pattern, &self.pattern) |*bank, *live| bank.* = live.load(.acquire);
        for (&slot.vel, &self.vel) |*bank_row, *live_row| {
            for (bank_row, live_row) |*bank, *live| bank.* = live.load(.acquire);
        }
        slot.step_count = self.step_count;
    }

    /// Replace the live pattern with `slot`'s data (control thread). Used to
    /// activate a bank variant and to paste a yanked pattern; setStepCount
    /// masks off any stray bits above the step count.
    pub fn applyVariant(self: *DrumMachine, slot: Variant) void {
        for (&self.pattern, slot.pattern) |*live, bits| live.store(bits, .release);
        for (&self.vel, slot.vel) |*live_row, bank_row| {
            for (live_row, bank_row) |*live, v| live.store(v, .release);
        }
        self.setStepCount(slot.step_count);
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

    /// Duplicate the active variant into a new slot and switch to it — the
    /// live pattern already matches the copy. False when the bank is full.
    pub fn addVariant(self: *DrumMachine) bool {
        if (self.variant_count >= max_variants) return false;
        self.storeActiveVariant();
        self.variants[self.variant_count] = self.variants[self.variant];
        self.variant = self.variant_count;
        self.variant_count += 1;
        return true;
    }

    /// Remove the active variant, shifting later slots down. The slot that
    /// takes its index (or the new last) becomes active. False when it's the
    /// only one left.
    pub fn removeVariant(self: *DrumMachine) bool {
        if (self.variant_count <= 1) return false;
        var i = self.variant;
        while (i + 1 < self.variant_count) : (i += 1) self.variants[i] = self.variants[i + 1];
        self.variant_count -= 1;
        if (self.variant >= self.variant_count) self.variant = self.variant_count - 1;
        self.loadVariantLive(self.variant);
        return true;
    }

    /// Variant `v`'s pattern data. The active one is read from the live
    /// atomics (its bank slot is stale until the next switch).
    pub fn variantData(self: *const DrumMachine, v: u8) Variant {
        if (v == self.variant) {
            var out: Variant = .{ .step_count = self.step_count };
            for (&out.pattern, &self.pattern) |*dst, *live| dst.* = live.load(.acquire);
            for (&out.vel, &self.vel) |*dst_row, *live_row| {
                for (dst_row, live_row) |*dst, *live| dst.* = live.load(.acquire);
            }
            return out;
        }
        return self.variants[@min(v, max_variants - 1)];
    }

    /// Display letter for variant `v`: A, B, C, …
    pub fn variantLetter(v: u8) u8 {
        return 'A' + @as(u8, @min(v, max_variants - 1));
    }

    /// Replace the song-mode clip timeline (control thread). Taken under
    /// `pad_lock` so the audio thread never reads a half-written array.
    pub fn setSongClips(self: *DrumMachine, clips: []const SongClip, length_steps: u32) void {
        while (!self.pad_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.pad_lock.unlock();
        const count = @min(clips.len, @as(usize, max_song_clips));
        for (clips[0..count], self.song_clips[0..count]) |src, *dst| dst.* = src;
        self.song_clip_count = @intCast(count);
        self.song_length_steps = length_steps;
    }

    pub fn toggleStep(self: *DrumMachine, pad: u8, step: u8) void {
        if (pad >= max_pads or step >= max_steps) return;
        const bit = @as(u64, 1) << @intCast(step);
        _ = self.pattern[pad].fetchXor(bit, .acq_rel);
        // A toggled step always (re)starts at full velocity.
        self.vel[pad][step].store(vel_full, .release);
    }

    pub fn stepActive(self: *const DrumMachine, pad: u8, step: u8) bool {
        if (pad >= max_pads or step >= max_steps) return false;
        return (self.pattern[pad].load(.acquire) >> @intCast(step)) & 1 == 1;
    }

    /// One step's velocity, 0-127 (127 = full, see velGain).
    pub fn stepVel(self: *const DrumMachine, pad: u8, step: u8) u8 {
        if (pad >= max_pads or step >= max_steps) return vel_full;
        return self.vel[pad][step].load(.acquire);
    }

    pub fn setStepVel(self: *DrumMachine, pad: u8, step: u8, level: u8) void {
        if (pad >= max_pads or step >= max_steps) return;
        self.vel[pad][step].store(level, .release);
    }

    /// Cycle through the named preset bands (127→95→63→31→127) — a quick
    /// single-key gesture; `nudgeStepVel` covers the full 1-127 range.
    pub fn cycleStepVel(self: *DrumMachine, pad: u8, step: u8) void {
        const cur = self.stepVel(pad, step);
        var idx: usize = vel_presets.len - 1; // not a preset value -> next lands on preset[0]
        for (vel_presets, 0..) |v, i| {
            if (v == cur) { idx = i; break; }
        }
        self.setStepVel(pad, step, vel_presets[(idx + 1) % vel_presets.len]);
    }

    /// Nudge one step's velocity by `delta`, clamped to 1..127 — 0 would be
    /// silent; use x/X to remove a step instead of zeroing its velocity.
    pub fn nudgeStepVel(self: *DrumMachine, pad: u8, step: u8, delta: i32) void {
        const cur: i32 = self.stepVel(pad, step);
        const next = std.math.clamp(cur + delta, 1, 127);
        self.setStepVel(pad, step, @intCast(next));
    }

    /// Wipe one pad's row: no steps, all velocities back to full.
    pub fn clearPad(self: *DrumMachine, pad: u8) void {
        if (pad >= max_pads) return;
        self.pattern[pad].store(0, .release);
        for (&self.vel[pad]) |*p| p.store(vel_full, .release);
    }

    /// Fill one pad's row with full-velocity steps across the active length.
    pub fn fillPad(self: *DrumMachine, pad: u8) void {
        if (pad >= max_pads) return;
        self.pattern[pad].store(stepMask(self.step_count), .release);
        for (&self.vel[pad]) |*p| p.store(vel_full, .release);
    }

    pub fn padName(self: *const DrumMachine, pad: u8) []const u8 {
        if (pad >= max_pads) return "----";
        if (self.pads[pad]) |*s| return s.clipName();
        return "empty";
    }

    /// Current sequencer step — read by the UI to highlight the playhead.
    pub fn currentStep(self: *const DrumMachine) u8 {
        return self.current_step.load(.monotonic);
    }

    /// Encode a (pad, param) pair into the `set_param` id space.
    pub fn paramId(pad: u8, param: u8) u16 {
        return (@as(u16, pad) << 4) | (param & 0x0F);
    }

    /// Nudge a per-pad sampler param by `steps` (h/l = ±1, H/L = ±10). Runs on
    /// the audio thread via the `set_param` event so it never races the block
    /// reader, mirroring PolySynth.adjustParam. The pad index is the high bits
    /// of `id`; the param index is the low nibble (see `paramId`). Delegates
    /// straight to the pad's own Sampler.adjustParam — pads only ever receive
    /// param indices 0..9 (the drum grid never exposes Sampler's root-note
    /// param 10). A no-op on an unloaded (null) pad — nothing to nudge.
    pub fn adjustParam(self: *DrumMachine, id: u16, steps: i32) void {
        const pad_idx: u8 = @intCast(id >> 4);
        const param: u8 = @intCast(id & 0x0F);
        if (pad_idx >= max_pads) return;
        if (self.pads[pad_idx]) |*s| s.adjustParam(param, steps);
    }

    // -----------------------------------------------------------------------
    // Sample loading (call from control side only, not while audio thread runs)

    /// Materialize pad `idx` if it's still null (never loaded), returning a
    /// pointer to it either way. A freshly materialized Sampler briefly
    /// carries the generated default clip — the caller (setPadSamples/
    /// loadPadWav) immediately replaces it, so this is a transient
    /// allocation, not a persistent cost (see the `pads` field's own doc
    /// comment for why lazy materialization matters at 64 slots). Caller
    /// must have already bounds-checked `idx`.
    fn ensurePad(self: *DrumMachine, idx: u8) !*Sampler {
        if (self.pads[idx] == null) {
            self.pads[idx] = try Sampler.init(self.allocator, self.sample_rate);
        }
        return &self.pads[idx].?;
    }

    /// Replace pad `idx` with external mono f32 samples (must be allocated
    /// with `self.allocator`; the pad's Sampler takes ownership). Resets every
    /// other pad param to its default — used for a clean-slate kit pad, not
    /// user WAV loading (see `loadPadWav`, which preserves params).
    /// Materializes the pad if it was still null.
    pub fn setPadSamples(
        self: *DrumMachine,
        idx: u8,
        samples: []f32,
        name: []const u8,
    ) void {
        if (idx >= max_pads) return;
        const pad = self.ensurePad(idx) catch {
            self.allocator.free(samples); // materialize failed — don't leak the caller's buffer
            return;
        };
        pad.setSamples(samples, name);
    }

    /// Regenerate the kit variant's pads (always the first 8 — kits are an
    /// 8-pad concept regardless of `max_pads`; see `dsp/drum_kit.zig`'s
    /// `variants` table) from procedural generators. Runs them directly into
    /// fresh pad buffers — nothing is read from disk or the binary's
    /// embedded assets, so extra kit flavours cost no shipped bytes. Marks
    /// every pad as non-user so it isn't exported to the sample sidecar.
    pub fn loadKitVariant(self: *DrumMachine, variant: *const drum_kit.KitVariant) !void {
        for (variant.pads, 0..) |slot, i| {
            const samples = try slot.gen(self.allocator, self.sample_rate);
            self.setPadSamples(@intCast(i), samples, slot.name);
            self.pads[i].?.pad.gain = slot.gain;
        }
    }

    /// Parse raw WAV bytes into pad `idx`, keeping its other params (pitch,
    /// trim, ADSR, gain, …) untouched — same as loading a new clip into the
    /// standalone Sampler. Resamples to engine rate if needed. Materializes
    /// the pad if it was still null.
    pub fn loadPadWav(self: *DrumMachine, idx: u8, wav_data: []const u8, name: []const u8) !void {
        if (idx >= max_pads) return;
        const pad = try self.ensurePad(idx);
        try pad.loadWav(wav_data, name);
    }

    // -----------------------------------------------------------------------
    // Audio thread processing

    fn framesPerStep(self: *const DrumMachine) f64 {
        // One step = sixteenth note (1/4 beat)
        const bpm = @max(self.transport.tempo_bpm, 1.0);
        const fpb = @as(f64, @floatFromInt(self.sample_rate)) * 60.0 / bpm;
        return @max(1.0, fpb / 4.0);
    }

    pub fn processBlock(self: *DrumMachine, buf: []Sample) void {
        const channels = 2;
        const frames: u32 = @intCast(buf.len / channels);

        while (!self.pad_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.pad_lock.unlock();

        if (self.transport.playing) {
            const pos_f = @as(f64, @floatFromInt(self.transport.position_frames));
            const fps = self.framesPerStep();
            // Swing: off-beat 16ths (odd step_k) fire late by up to half a
            // step (75% = hardest shuffle). Even steps stay on the grid, so
            // the boundary positions remain strictly increasing.
            const swing_pct = self.swing.load(.monotonic);
            const swing_delay: f64 = fps * @as(f64, swing_pct - 50.0) / 50.0;
            var step_k = self.next_step_k;

            // Resync on discontinuity (seek, loop, first play after stop)
            const expected = @as(f64, @floatFromInt(step_k)) * fps;
            if (@abs(expected - pos_f) > fps * 2.0) {
                step_k = @intFromFloat(@ceil(pos_f / fps));
            }

            // Fire every step whose boundary falls inside [pos_f, pos_f+frames)
            while (true) {
                var fire_pos = @as(f64, @floatFromInt(step_k)) * fps;
                if (step_k & 1 == 1) fire_pos += swing_delay;
                if (fire_pos >= pos_f + @as(f64, @floatFromInt(frames))) break;

                const fire_frame: u32 = if (fire_pos <= pos_f)
                    0
                else
                    @intCast(@min(
                        @as(u64, @intFromFloat(fire_pos - pos_f)),
                        @as(u64, frames - 1),
                    ));

                if (self.song_mode) {
                    self.fireSongStep(step_k, fire_frame);
                } else {
                    const step_idx: u8 = @intCast(step_k % self.step_count);
                    for (0..max_pads) |p| {
                        if ((self.pattern[p].load(.acquire) >> @intCast(step_idx)) & 1 == 1) {
                            self.chokeTrigger(@intCast(p), velGain(self.stepVel(@intCast(p), step_idx)), fire_frame);
                        }
                    }
                    self.current_step.store(step_idx, .monotonic);
                }
                step_k += 1;
            }

            self.next_step_k = step_k;
        }

        for (&self.pads) |*p| if (p.*) |*s| s.processBlock(buf);
    }

    /// Fire pads for absolute step `step_k` from the song timeline. Past
    /// `song_length_steps` this goes silent instead of wrapping — the
    /// arrangement plays once through, not on a loop.
    fn fireSongStep(self: *DrumMachine, step_k: u64, fire_frame: u32) void {
        if (self.song_length_steps == 0 or step_k >= self.song_length_steps) return;
        const lk: u32 = @intCast(step_k);
        for (self.song_clips[0..self.song_clip_count]) |*clip| {
            if (lk < clip.start_step or lk >= clip.start_step + clip.span_steps) continue;
            if (clip.step_count == 0) return;
            const local: u32 = (lk - clip.start_step) % clip.step_count;
            for (0..max_pads) |p| {
                if ((clip.pattern[p] >> @intCast(local)) & 1 == 1) {
                    self.chokeTrigger(@intCast(p), velGain(clip.vel[p][local]), fire_frame);
                }
            }
            self.current_step.store(@intCast(local), .monotonic);
            return; // clips never overlap
        }
        // No clip under the playhead: keep the UI step indicator moving
        // through the gap instead of freezing on the last clip's step.
        self.current_step.store(@intCast(lk % self.step_count), .monotonic);
    }

    /// Trigger pad `p` at its own root (no chromatic shift) after clearing any
    /// voice already in flight — a retrigger always chokes the previous hit,
    /// the classic drum-machine convention, even though the underlying
    /// Sampler is itself polyphonic. If `p` belongs to a choke group (nonzero
    /// `choke_group`), every other pad sharing that group is silenced too
    /// (e.g. a closed-hat hit cutting an open hat's ring-out). A no-op on an
    /// unloaded (null) pad — nothing to trigger.
    fn chokeTrigger(self: *DrumMachine, p: u8, vel: f32, block_start: u32) void {
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
        pad.trigger(pad.root_note, vel, block_start);
    }

    fn triggerPad(self: *DrumMachine, pad_idx: u8, vel: f32) void {
        if (pad_idx >= max_pads) return;
        self.chokeTrigger(pad_idx, vel, 0);
    }

    pub fn resetAll(self: *DrumMachine) void {
        for (&self.pads) |*p| if (p.*) |*s| s.resetAll();
        self.next_step_k = 0;
    }

    fn processOpaque(ptr: *anyopaque, buf: []Sample) void {
        const self: *DrumMachine = @ptrCast(@alignCast(ptr));
        self.processBlock(buf);
    }

    fn eventOpaque(ptr: *anyopaque, ev: dsp.Event) void {
        const self: *DrumMachine = @ptrCast(@alignCast(ptr));
        switch (ev) {
            .note_on  => |e| self.triggerPad(e.note % max_pads, e.velocity),
            .set_param => |e| self.adjustParam(e.id, e.steps),
            .note_off, .cc, .pitch_bend, .set_param_abs => {},
            .all_off  => self.resetAll(),
        }
    }

    fn resetOpaque(ptr: *anyopaque) void {
        const self: *DrumMachine = @ptrCast(@alignCast(ptr));
        self.resetAll();
    }
};

// -----------------------------------------------------------------------
// Tests

test "embedded kit loads non-silent pads with default gains" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    // All 8 kit pads should decode and have samples + their default gain.
    for (0..8) |p| {
        try std.testing.expect(dm.pads[p].?.pad.samples.len > 0);
        try std.testing.expect(dm.pads[p].?.pad.gain > 0.0);
    }
    // Pads beyond the kit's 8 are lazily unmaterialized.
    for (8..DrumMachine.max_pads) |p| {
        try std.testing.expect(dm.pads[p] == null);
    }
    // Kick should have a non-zero peak.
    var peak: f32 = 0;
    for (dm.pads[0].?.pad.samples) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.01);
    // Hihat ships quieter than the kick by default.
    try std.testing.expect(dm.pads[2].?.pad.gain < dm.pads[0].?.pad.gain);
}

test "step sequencer fires pads at correct boundaries" {
    var transport: Transport = .{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    // Clear all defaults; enable only pad 0 on step 0
    for (&dm.pattern) |*p| p.store(0, .monotonic);
    dm.pattern[0].store(1, .monotonic); // step 0 active

    // At 120bpm, 16th note = 6000 frames. Start playing at frame 0.
    transport.play();
    var buf: [512]Sample = undefined; // 256 frames * 2 channels
    @memset(&buf, 0.0);
    dm.processBlock(&buf);

    // Step 0 fires at frame 0 — pad 0 should be audible
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

test "song mode fires the clip covering the playhead" {
    var transport: Transport = .{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    // Clear the default groove; song mode reads only song_clips.
    for (&dm.pattern) |*p| p.store(0, .monotonic);

    // Two bars long. A single clip in bar 1 (steps 16..31) fires pad 0 on its
    // first step; bar 0 is empty.
    var pat = [_]u64{0} ** DrumMachine.max_pads;
    pat[0] = 1; // local step 0
    const clips = [_]DrumMachine.SongClip{.{
        .start_step = 16, .span_steps = 16, .step_count = 16, .pattern = pat,
    }};
    dm.setSongClips(&clips, 32);
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

test "note_on triggers pad directly" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
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

    dm.pattern[0].store(0, .monotonic);
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
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
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
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
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

test "swing delays the off-beat step" {
    var transport: Transport = .{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    // Only pad 0 on step 1 (an off-beat 16th). At 120bpm a step is 6000
    // frames; swing 75% pushes step 1's hit from 6000 to 9000.
    for (&dm.pattern) |*p| p.store(0, .monotonic);
    dm.pattern[0].store(1 << 1, .monotonic);
    dm.adjustSwing(100.0); // clamps at swing_max = 75
    try std.testing.expectApproxEqAbs(DrumMachine.swing_max, dm.swing.load(.monotonic), 1e-6);

    transport.play();
    var buf: [512]Sample = undefined; // 256 frames

    // Silent through the straight boundary (6000) up to just before 9000.
    while (transport.position_frames < 8960) {
        @memset(&buf, 0.0);
        dm.processBlock(&buf);
        var peak: f32 = 0;
        for (buf) |s| peak = @max(peak, @abs(s));
        try std.testing.expect(peak < 0.01);
        transport.advance(256);
    }
    // The block covering frame 9000 fires the swung step.
    @memset(&buf, 0.0);
    dm.processBlock(&buf);
    var peak: f32 = 0;
    for (buf) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.01);
}

test "variants keep per-step velocity" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    for (&dm.pattern) |*p| p.store(0, .monotonic);
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

test "toggleStep flips pattern bit" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    dm.pattern[0].store(0, .monotonic);
    dm.toggleStep(0, 3);
    try std.testing.expect(dm.stepActive(0, 3));
    dm.toggleStep(0, 3);
    try std.testing.expect(!dm.stepActive(0, 3));
}

test "variants: add copies, edits stay isolated, select round-trips" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    for (&dm.pattern) |*p| p.store(0, .monotonic);
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
    try std.testing.expectEqual(@as(u8, 32), dm.step_count); // default, untouched
    dm.selectVariant(1);
    try std.testing.expectEqual(@as(u8, 24), dm.step_count);
}

test "variants: cycle wraps and remove shifts the bank down" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    try std.testing.expect(!dm.removeVariant()); // can't drop the only one
    dm.cycleVariant(1); // single variant: no-op
    try std.testing.expectEqual(@as(u8, 0), dm.variant);

    _ = dm.addVariant(); // B
    _ = dm.addVariant(); // C — mark it
    for (&dm.pattern) |*p| p.store(0, .monotonic);
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

test "variantData reads the active variant from the live atomics" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    for (&dm.pattern) |*p| p.store(0, .monotonic);
    dm.toggleStep(3, 9); // edit after the bank slot was last synced
    const active = dm.variantData(dm.variant);
    try std.testing.expectEqual(@as(u64, 1 << 9), active.pattern[3]);
}

test "setStepCount discards bits beyond the new count" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    dm.setStepCount(32);
    dm.pattern[0].store(1 << 20, .monotonic);
    dm.setStepCount(16); // shrink: bit 20 must not survive
    dm.setStepCount(32); // grow back
    try std.testing.expect(!dm.stepActive(0, 20));
}

test "step count grows to 64 (u64 bitmask width) and the sequencer fires the last step" {
    var transport: Transport = .{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    dm.setStepCount(64);
    try std.testing.expectEqual(@as(u8, 64), dm.step_count);
    // A count past the ceiling clamps, it doesn't wrap or overflow the u8.
    dm.setStepCount(200);
    try std.testing.expectEqual(@as(u8, 64), dm.step_count);

    for (&dm.pattern) |*p| p.store(0, .monotonic);
    dm.toggleStep(0, 63); // the highest bit the u64 bitmask can hold
    try std.testing.expect(dm.stepActive(0, 63));
    dm.setStepVel(0, 63, 31);
    try std.testing.expectEqual(@as(u8, 31), dm.stepVel(0, 63));

    // The bit actually lives at u64 bit 63, not truncated/wrapped into a
    // lower bit by a stale u32 shift somewhere in the pipeline.
    try std.testing.expectEqual(@as(u64, 1) << 63, dm.pattern[0].load(.monotonic));

    // Step 63 fires at 6000 * 63 = 378_000 frames (120bpm, 16th = 6000 frames).
    transport.play();
    transport.seekFrames(377_950);
    var buf: [512]Sample = undefined; // 256 frames
    dm.resetAll();
    @memset(&buf, 0.0);
    dm.processBlock(&buf);
    var peak: f32 = 0;
    for (buf) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.01);
}

test "adjustParam decodes pad/param and clamps" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
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

test "region trim shortens the voice" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
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
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
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

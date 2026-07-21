//! Shared types for audio-input capture, split out from `capture.zig` so
//! the platform-specific capture backends (`AlsaCapture` in `alsa.zig`,
//! `WasapiCapture` in `wasapi.zig`) and the OS-picking dispatcher
//! (`capture.zig`'s `AudioInput`) all agree on one canonical block type
//! without an import cycle between them.

const std = @import("std");
const types = @import("../core/types.zig");
const Spsc = @import("../core/ring_buffer.zig").Spsc;

/// One chunk of captured mono input, read on the capture thread and
/// drained on the control thread. Sized to `chunk_frames`, not
/// `types.max_block_frames` - capture reads fixed small chunks
/// independent of whatever block size the output backend negotiated.
pub const chunk_frames: u32 = types.default_block_frames;

pub const CaptureBlock = struct {
    samples: [chunk_frames]types.Sample = undefined,
    frames: u32 = 0,
};

/// Capacity headroom between capture-thread pushes and the control
/// thread's per-frame drain (see `App.tick`) - same lock-free tolerance
/// `midi_in.zig`'s `note_queue` already accepts (a full queue just drops
/// the newest block rather than blocking the capture thread).
pub const Queue = Spsc(CaptureBlock, 32);

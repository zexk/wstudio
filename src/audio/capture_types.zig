//! Shared types for audio-input capture, split out from `capture.zig` so
//! the platform-specific capture backends (`AlsaCapture` in `audio/backends/alsa.zig`,
//! `WasapiCapture` in `audio/backends/wasapi.zig`) and the OS-picking dispatcher
//! (`capture.zig`'s `AudioInput`) all agree on one canonical block type
//! without an import cycle between them.

const types = @import("../core/types.zig");
const Spsc = @import("../core/ring_buffer.zig").Spsc;

pub const channel_count: u8 = 2;

/// One chunk of captured stereo input, read on the capture thread and
/// drained on the control thread. Sized to `chunk_frames`, not
/// `types.max_block_frames` - capture reads fixed small chunks
/// independent of whatever block size the output backend negotiated.
pub const chunk_frames: u32 = types.default_block_frames;

pub fn validateSampleRate(sample_rate: u32) error{InvalidSampleRate}!void {
    if (sample_rate == 0) return error.InvalidSampleRate;
}

pub const CaptureBlock = struct {
    samples: [chunk_frames * channel_count]types.Sample = undefined,
    frames: u32 = 0,
    channels: u8 = channel_count,
    start_frame: u64 = 0,
};

pub const Dropout = struct { start_frame: u64, frames: u32 };

/// Capacity headroom between capture-thread pushes and the control
/// thread's per-frame drain (see `App.tick`) - same lock-free tolerance
/// `audio/midi/linux.zig`'s `note_queue` already accepts (a full queue just drops
/// the newest block rather than blocking the capture thread).
pub const Queue = Spsc(CaptureBlock, 32);
pub const DropoutQueue = Spsc(Dropout, 32);

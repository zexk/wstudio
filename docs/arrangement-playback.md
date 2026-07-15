# Arrangement playback

The arrangement is the song-mode counterpart to each track's live pattern.
Pattern mode loops one live pattern per track. Song mode instead sweeps a bar
timeline and plays whichever clip is under the playhead on each track lane.

Clips own private copies of their musical content. A melodic clip owns its
notes, while a drum or slicer clip owns its step data. Editing or duplicating
one clip therefore cannot change another clip or the live pattern it was
stamped from.

The `Arrangement` itself is control-side state and is never read by the audio
thread. `Session.rebuildSongData` flattens the lane clips into the same
per-track devices used in pattern mode. Those devices then replay the flattened
timeline against the transport. Keeping both playback modes on the same device
path avoids a second audio-thread representation of instruments and effects.

See `src/arrangement.zig` for clip storage and `src/session.zig` for the
flattening step.

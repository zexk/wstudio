# Arrangement playback

The arrangement is the song-mode counterpart to each track's live pattern.
Pattern mode loops one live pattern per track. Song mode instead sweeps a tick
timeline (`time_grid.ticks_per_beat` per quarter note) and plays whichever clip
is under the playhead on each track lane. Bars are derived from that timeline
through `Project.barAtTick`, never by dividing by one fixed bar length: a
meter point opens a new bar and cuts the one it lands in short.

Clips own private copies of their musical content. A melodic clip owns its
notes, while a drum or slicer clip owns its step data. Editing or duplicating
one clip therefore cannot change another clip or the live pattern it was
stamped from. An audio clip is the exception: it holds a region addressing a
shared source in `Project.audio_sources`, not a copy of the audio.

Each clip also carries its own gain/pan and instrument/FX-param automation,
in clip-relative beats. A point past the clip's own span is kept but not
played, so shortening a clip hides its trailing curve rather than destroying
it, and growing the clip back brings it out again.

A lane holds its clips sorted by start tick. Two clips on the same layer never
overlap - placing one evicts what it lands on - but clips on different layers
deliberately do, and `clipAt` reports the topmost.

The `Arrangement` itself is control-side state and is never read by the audio
thread. `Session.rebuildSongData` flattens the lane clips into the same
per-track devices used in pattern mode. Those devices then replay the flattened
timeline against the transport. Keeping both playback modes on the same device
path avoids a second audio-thread representation of instruments and effects.

See `src/arrangement.zig` for clip storage and `src/session.zig` for the
flattening step.

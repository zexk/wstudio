# Undo and redo

Undo history belongs to the TUI and runs only on the UI thread. Before a
content edit, the app captures the whole state of the domain being changed:
one melodic pattern, one drum or slicer pattern bank, one arrangement lane, or
one FX chain. Undo swaps that snapshot with the live state. The displaced live
state becomes the redo entry, so both directions use the same operation.

An arrangement edit that spans several lanes at once - a linewise (`V`)
visual range across every track - captures all of them into a single
multi-lane entry instead, so one `u` puts the whole section back rather than
needing one per lane. If a track is later deleted, such an entry drops just
that track's lane and keeps the rest, since the others are still restorable.

The arrangement's named sections are content too, so `:section` and
`:section-del` capture the marker list on its own rather than every lane's
clips.

Parameter nudges are the exception. Synth, sampler, and FX parameters live on
the audio thread, so a nudge records one absolute before-value and restores it
through the same event path used by automation. Rapid repeated nudges of the
same parameter and unit coalesce into one history entry.

History deliberately covers content editing, not every mutable value. Every
edit to the track list is in scope and shares the two structural entry types:
creation (`a`), duplication (`Y`), deletion (`dd`, which restores through its
own whole-rack snapshot), and an already-populated track's instrument swap
(`:track-instrument`, the `I` keybind). Mixer gain and pan record a
before-value the same way a parameter nudge does.

What stays out of scope is per-track mix state that is toggled rather than
edited: mute, solo, and track colour. Those are saved in the project and mark
it dirty, but `u` does not put them back. `src/tui/app_tests.zig`'s "undo
restores the project byte for byte" pins both halves of this - it saves either
side of a `u` and compares the files, and lists the exclusions explicitly, so
moving one in or out of scope has to be a deliberate edit to that table. Its
companion, "every no-arg command that edits the project is undoable", walks
the whole command table the same way, so a new command cannot quietly join
the exclusions.

Group buses are out of scope for the same reason. `:group-add` and
`:group-del` change the project and mark it dirty, but `u` does not put a
group back: a group is addressed by index from every track assigned to it, so
a stored snapshot would need the same remap-or-drop pass as below. Deleting a
group already drops its members back to the master mix rather than leaving
them pointing at a free slot, so the state is never inconsistent, only
manual to reverse.

The mix-automation lanes `:automation-point` writes (master gain, group gain,
send level) are out of scope too, unlike the clip automation that rides inside
a clip and is covered by the lane snapshot. Two reasons: the same lanes are
also written a point at a time by `automation-mode` recording while the
transport runs, which would flood the stack, and a lane addresses a track by
index, so a stored snapshot would need the same remap-or-drop pass
`Session.remapTrackReferences` does for the live list or it could restore a
curve onto a track that is no longer the one it was written for. Correcting a
mistyped point means writing the point again at the same beat.

The history is bounded, and failure to allocate a snapshot does not block the
edit.

The entry types and swap mechanics live in `src/ui/undo.zig`. Capture,
restoration, coalescing, and the shared `u`/`U` entry points live in
`src/ui/history.zig`.

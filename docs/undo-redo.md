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
moving one in or out of scope has to be a deliberate edit to that table.

The history is bounded, and failure to allocate a snapshot does not block the
edit.

The entry types and swap mechanics live in `src/ui/undo.zig`. Capture,
restoration, coalescing, and the shared `u`/`U` entry points live in
`src/ui/history.zig`.

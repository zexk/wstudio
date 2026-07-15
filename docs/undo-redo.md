# Undo and redo

Undo history belongs to the TUI and runs only on the UI thread. Before a
content edit, the app captures the whole state of the domain being changed:
one melodic pattern, one drum or slicer pattern bank, one arrangement lane, or
one FX chain. Undo swaps that snapshot with the live state. The displaced live
state becomes the redo entry, so both directions use the same operation.

Parameter nudges are the exception. Synth, sampler, and FX parameters live on
the audio thread, so a nudge records one absolute before-value and restores it
through the same event path used by automation. Rapid repeated nudges of the
same parameter and unit coalesce into one history entry.

History deliberately covers content editing, not every mutable value. Track
creation and deletion, instrument swaps, swing, and mixer gain and pan are out
of scope. The history is bounded, and failure to allocate a snapshot does not
block the edit.

The entry types and swap mechanics live in `src/tui/undo.zig`. Capture,
restoration, coalescing, and the shared `u`/`U` entry points live in
`src/tui/history.zig`.

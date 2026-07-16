# docs/

Design context that is worth keeping but too long to live in code
comments. Code comments explain the why of the trickiest or most
arbitrary steps in place; when the explanation is really a shared
convention or a design story spanning files, it belongs here and the
code keeps a one-line pointer.

- [editing-grammar.md](editing-grammar.md): the vim grammar every
  pattern editor shares (counts, operators, motions, visual mode,
  dot-repeat) and how each editor maps the char/word/line hierarchy.
- [arrangement-playback.md](arrangement-playback.md): how pattern and song
  playback share devices, and why arrangement clips own their content.
- [undo-redo.md](undo-redo.md): snapshot boundaries, swap-based history,
  parameter-nudge coalescing, and the deliberately limited undo scope.
- [user-config-storage.md](user-config-storage.md): paths, atomic JSON writes,
  corrupt-file quarantine, and the boundary between drum tuning and audio.
- [ui-conventions.md](ui-conventions.md): TUI layout and chrome
  conventions (row budget, status row, prompt row, frame bracketing,
  icon fallback) plus the design decisions behind them.
- [gui-color-identity.md](gui-color-identity.md): the GUI's Patina palette,
  semantic color roles, and the category patterns it intentionally avoids.

Related documents that predate this directory and stay where they are:
`README.md` (pitch, layout, usage), `FORMAT.md` (the `.wsj` save format,
versioning policy, and the canonical version history).

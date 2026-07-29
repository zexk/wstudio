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
- [beta-5-goals.md](beta-5-goals.md): beta.5 goals and exit criteria.
- [beta-6-goals.md](beta-6-goals.md): bounded VST3 hosting baseline.
- [beta-7-goals.md](beta-7-goals.md): complete-project production workflow
  journeys, blocker policy, and exit criteria.
- [beta-7-validation.md](beta-7-validation.md): exact journey, soak, export,
  fault-injection, and environment coverage commands.
- [beta-8-goals.md](beta-8-goals.md): compatibility freeze for project files,
  Lua/config, commands, input grammar, CLI behavior, and plugin persistence.
- [compatibility-inventory.md](compatibility-inventory.md): beta.8 freeze,
  migration, removal, and internal dispositions with authoritative registries.
- [road-to-1.0.md](road-to-1.0.md): release themes from beta.5 through the
  1.0 feature freeze.
- [ui-conventions.md](ui-conventions.md): TUI layout and chrome
  conventions (row budget, status row, prompt row, frame bracketing,
  icon fallback) plus the design decisions behind them.
- [gui-color-identity.md](gui-color-identity.md): the GUI's Patina palette,
  semantic color roles, and the category patterns it intentionally avoids.

Related documents that predate this directory and stay where they are:
`README.md` (pitch, layout, usage), `FORMAT.md` (the `.wsj` save format,
versioning policy, and the canonical version history).

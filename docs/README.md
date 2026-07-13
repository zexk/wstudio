# docs/

Design context that is worth keeping but too long to live in code
comments. Code comments explain the why of the trickiest or most
arbitrary steps in place; when the explanation is really a shared
convention or a design story spanning files, it belongs here and the
code keeps a one-line pointer.

- [editing-grammar.md](editing-grammar.md): the vim grammar every
  pattern editor shares (counts, operators, motions, visual mode,
  dot-repeat) and how each editor maps the char/word/line hierarchy.
- [ui-conventions.md](ui-conventions.md): TUI layout and chrome
  conventions (row budget, status row, prompt row, frame bracketing,
  icon fallback) plus the design decisions behind them.

Related documents that predate this directory and stay where they are:
`README.md` (pitch, layout, usage), `FORMAT.md` (the `.wsj` save format,
versioning policy, and the canonical version history).

# wstudio

Keyboard-centric DAW written in Zig 0.16, vim-modal TUI. See README.md for
the pitch/status and `src/` layout; FORMAT.md for the `.wsj` save format
and its versioning policy.

## Build / run / test

`.envrc` loads the nix devShell automatically; if it hasn't, prefix
commands with `nix develop --command`.

```
zig build run              # launch the TUI
zig build run -- demo.wsj  # curated four-track demo project
zig build test             # all tests
zig build genkit            # re-render the embedded drum kit after editing drum_kit.zig
zig build gendemo           # re-write demo.wsj after editing tools/gendemo.zig
nix run .#neutral-terminal  # launch Kitty with a clean Nerd Font configuration
```

**`zig build test` does not reliably rebuild `zig-out/bin/wstudio`** -
it's a separate build target. Before any interactive/tmux verification
pass, run plain `zig build` first, or a passing test suite can mask a
stale binary that looks like a real behavioral bug.

For visual verification of TUI changes, follow
[`docs/tui-screenshots.md`](docs/tui-screenshots.md). It drives a dedicated
tmux socket and renders a real PNG, which catches bg-color/reverse-video/
layout bugs that text captures miss.

## Hard rules

- **`zig fmt` is allowed, the fences are law.** The deliberately compact
  regions (param tables, one-line switch-arm key handlers, grouped
  struct-literal fields, aligned assignment blocks) are wrapped in
  `// zig fmt: off` / `// zig fmt: on` markers, so `zig fmt` is safe and
  encouraged on any file you touch. Never hand-reflow a fenced region to
  fmt style; if you write NEW code in that compact style and fmt would
  mangle it, extend or add a fence rather than skipping fmt. The global
  `nix fmt` convention is still for `.nix` files only.
- **Never `git add -A` or `-u`.** Stage files by name. `-A` has already
  swept a stray `demo.wsj~` backup into a feature commit once. Run
  `git status --short` and eyeball every untracked/modified entry before
  staging; if something doesn't belong to the current change, leave it.
- **Commit as you go, without asking first.** One logical change (feature,
  fix, UX pass) = one commit, right after it's working and tested. This
  repo has standing authorization for routine commits (not force-push or
  history rewrites, which still need asking).
- **No em dashes in new prose** (commit messages, code comments, README
  additions, help text). The ones already in the codebase predate this
  convention; don't clean them up, but don't add new ones either.
- **Comments explain the why of tricky or arbitrary steps, nothing more.**
  No narration of what the next line does, no session history ("an earlier
  pass tried..."), no duplicated essays across files. Shared conventions
  and design stories live in docs/ (see docs/README.md); code keeps a
  one-line pointer. Threading/atomics contracts in dsp/ and audio/ stay
  in the code, they are load-bearing.

## Zig 0.16 gotcha

`@min(comptime_bound, runtime_usize)` narrows the result to the smallest
int type that fits the *comptime* bound (e.g. `@min(18, rows -| 7)` gives
a `u5`), not the runtime operand's type. Arithmetic on that result can
overflow-panic despite the values being small and sane. Annotate the
destination (`const x: usize = @min(...)`) whenever the result feeds
further arithmetic.

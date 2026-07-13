# Editing grammar

The five pattern editors (piano roll, drum grid, slicer grid,
arrangement, automation) share one vim-flavored grammar. Each editor's
input file
(`src/tui/editors/<name>.zig`) implements it against its own axes; this
page is the canonical description, so per-editor comments only note
where that editor deviates.

## Modes

- **Normal**: motions and edits, listed below.
- **Insert** (`i`): the qwerty piano-key layout owns every key,
  including h/j/k/l, until escape. Editors bypass their own key switch
  entirely in insert mode; notes played while the transport rolls are
  recorded into the pattern (quantized against the audio thread's own
  playhead), otherwise insert is pure audition.
- **Visual** (`v`): anchors a time-range selection. Selections are
  time-range only in every editor: the piano roll selects all pitches
  across the step range, the drum and slicer grids all rows, and the
  arrangement restricts itself to the current lane (undo snapshots one
  lane at a time). `y`/`d` act on the range, escape cancels. While visual mode is
  active every unrelated key is swallowed so a stray press cannot
  switch views or curves mid-selection.
- **Command** (`:`) / **search** (`/`): handled outside the editors.

## Counts

A `1`-`9` prefix repeats the next motion (`3l`, `12h`, `2j`). Vim rule:
the count binds to the command it precedes and dies with it; a key the
editor handles discards any unused prefix. Digits typed while an
operator is pending extend the count without cancelling the operator.

## Motions

- `h`/`l`: one step (piano, drum, slicer, automation) or one bar
  (arrangement).
- `H`/`L`: 4 steps from wherever the cursor is (one beat), or 4 bars in
  the arrangement.
- `w`/`b`: one beat, snapped to beat boundaries (unlike `H`/`L`, which
  do not snap). The piano roll respects the triplet grid (6 steps per
  beat under `T`); the drum grid, slicer grid, and automation hardcode
  4 steps, matching the visual `|` separators. A true musical-bar jump was tried
  and rejected as too coarse: on a default 16-step pattern it crossed
  the whole visible grid in one press. The implementing functions are
  still named `jumpBar`/`barLenSteps` for historical reasons; despite
  the names the unit is one beat.
- `g`/`G`: start / end.
- `j`/`k`: the second axis where one exists (pitch, pad, lane, value
  nudge in automation). Never valid as an operator motion: operators
  are time-range only, matching visual mode.

## Operators

`d` and `y` arm an operator; a motion (`h`/`l`/`H`/`L`/`g`/`G`/`w`/`b`)
completes it over the range from the arming point to where the motion
lands. Doubling the key acts on the line tier (below). Any other key
cancels. `dw`/`yw` end at the last step of the nth beat forward, not at
`w`'s own landing step, mirroring vim's `dw` word-end nuance.

## The char/word/line hierarchy per editor

| editor      | char (`x`)       | word (`w`/`b`, `dw`) | line (`dd`)             |
|-------------|------------------|----------------------|-------------------------|
| piano roll  | note at cursor   | beat                 | cursor pitch's row      |
| drum grid   | step at cursor   | beat (4 steps)       | cursor pad's row (= X)  |
| slicer grid | step at cursor   | beat (4 steps)       | cursor slice's row (= X)|
| arrangement | clip under cursor| (bar IS the unit)    | whole lane              |
| automation  | point at cursor  | beat (4 steps)       | whole curve             |

The arrangement collapses a tier: a bar is already its atomic unit, so
`h`/`l` move by bars and there is no separate word motion size.

`yy` in the piano roll and drum grid is the whole-pattern yank rather
than a one-row yank: it is the cross-track pattern-copy vehicle (`p`
pastes it into another track), and a one-pitch/one-pad yank would have
no paste story of its own. Whole-pattern clears live in `:clear` or a
full-range visual `d`. The slicer grid's `yy` is a full-width range
yank instead (it has no pattern variants and its rows are clip-specific
chops, so there is no cross-track paste story).

## Paste

`p` pastes everywhere except the automation editor, where `p` opens the
param picker and `P` pastes instead.

## Dot-repeat

`.` repeats the last compound edit only: param nudges, note drags,
clip moves, and range operations. A repeated drag applies to the note
under the new cursor; a repeated range op reuses the same width at the
new cursor. `.` takes no count override.

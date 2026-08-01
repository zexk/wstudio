# Editing grammar

The five pattern editors (piano roll, drum grid, slicer grid,
arrangement, automation) share one vim-flavored grammar. Each editor's
input file
(`src/ui/editors/<name>.zig`) implements it against its own axes; this
page is the canonical description, so per-editor comments only note
where that editor deviates.

## Modes

- **Normal**: motions and edits, listed below.
- **Insert** (`i`): the qwerty piano-key layout owns every key,
  including h/j/k/l, until escape. Editors bypass their own key switch
  entirely in insert mode; notes played while the transport rolls are
  recorded into the pattern (quantized against the audio thread's own
  playhead), otherwise insert is pure audition.
- **Visual** (`v`) / **visual line** (`V`): anchors a selection. Both
  anchor the time axis; they differ on the second axis, the way vim's
  blockwise and linewise visual modes do. A "line" here is one full
  column of the grid at a step, so linewise means every pitch, pad, or
  slice.
  - `v` is blockwise: the selection also anchors to the cursor row, so it
    starts one row tall and `j`/`k` grow the band. This is what selects a
    single voice out of a chord, or one pad's fill.
  - `V` is linewise: the row axis is left open and every row is in. This
    is what visual mode did unconditionally before the row axis existed,
    so the old gesture is one shifted keystroke away.
  - The automation editor and the tracks list have no second axis, so
    `v` is the only form there.
  - In the arrangement a "row" is a lane, so `V` cuts or copies a bar
    range across every track at once. That lands as a single multi-lane
    undo entry (see docs/undo-redo.md), not one per lane.

  `y`/`d` act on the selection, escape cancels. While visual mode is
  active every unrelated key is swallowed so a stray press cannot
  switch views or curves mid-selection.

  In the piano roll, `enter` starts selected-note editing. `h`/`l` move
  every selected note in time, `j`/`k` transpose, `[`/`]` resize, and
  `<`/`>` change velocity. `enter` or escape returns to selection.
- **Command** (`:`) / **search** (`/`): handled outside the editors.

## Counts

A `1`-`9` prefix repeats the next motion (`3l`, `12h`, `2j`). Vim rule:
the count binds to the command it precedes and dies with it; a key the
editor handles discards any unused prefix. Digits typed while an
operator is pending extend the count without cancelling the operator.

A few commands read the count as a quantity rather than a repeat: `p`
pastes that many copies, `+`/`-` transpose by that many semitones, and the
piano roll's `c`/`C` chord stamp takes it as an inversion (`2c` = second
inversion). Those read the raw count, so a bare press means zero
inversions rather than one.

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
  nudge in automation). In blockwise visual mode they grow the selected
  row band. Never valid as an operator motion: `d`/`y` + a motion is
  always linewise, so `d3l` clears every row across the range it covers.
  `v` first is the route to a blockwise operator, exactly as in vim.

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

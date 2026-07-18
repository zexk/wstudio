# GUI optimization entries

Audit of the current GUI screenshots. These are design and layout observations only, with no implementation attached.

1. **FX editor: use the empty canvas**
   - `track_spectrum.png` leaves roughly 80% of the view blank.
   - Arrange parameters in columns or grouped panels.
   - Give visual effects a large primary display: EQ curve, compressor transfer curve and gain reduction, delay taps, reverb shape, and so on.
   - The selected effect should feel like an editor, not a short parameter list pinned to the upper-left.

2. **Master and group FX: create purposeful empty states**
   - `group_spectrum.png` and `master_spectrum.png` are almost entirely blank.
   - Use the space for a persistent spectrum, stereo meter, level history, signal-flow overview, or contextual explanation.
   - Merge the duplicate empty-chain messaging and insertion controls into one strong empty-state panel.
   - Master should expose useful master information even when its FX chain is empty.

3. **Tracks view: turn blank space into a mixer**
   - The track list occupies only the top third of the screen.
   - Increase row height and expose useful track controls: meter, pan, gain, mute, solo, arm, routing, instrument, and FX chain.
   - Give the master row real presence with a wide meter and master controls.
   - Consider a two-part layout: track list on the left and selected-track inspector or mixer strip on the right.
   - Avoid stretching sparse information across the full width merely because the window is wide.

4. **Drum grid: expand vertically**
   - The grid ends around 60% down the window while the rest is blank.
   - Stretch pad rows to fill the available height when only 12 pads are visible.
   - Alternatively, use the lower area for velocity, probability, ratchet, or per-step parameter lanes.
   - Make inactive pads visually quieter than named kit pieces.

5. **Arrangement: use the available height**
   - The arrangement occupies less than half the screenshot height.
   - Track lanes should expand to fill the viewport, within sensible maximums.
   - A selected-track inspector, clip inspector, automation lane, or overview strip could consume remaining space.
   - Make the empty lead lane visually meaningful instead of resembling an oversized selected cell.

6. **Synth editor: reduce scrolling and rebalance columns**
   - Large amounts of horizontal space coexist with vertically clipped parameter groups.
   - Replace the two long scrolling columns with denser grouped modules.
   - Arrange oscillator modules as cards, likely two or three columns depending on width.
   - Keep related controls, such as waveform/unison and tuning, together.
   - Avoid internal scrollbars where the whole screen has enough room to display more.
   - Give the top oscillator/envelope/filter preview slightly more height if it remains interactive or informative.

7. **Sampler: redistribute controls around the waveform**
   - A few knobs are stacked on the far left while most horizontal space is unused.
   - Make the waveform the primary canvas and overlay or place start/end markers directly on it.
   - Put playback, tuning, output, key, and envelope controls into compact horizontal modules.
   - The envelope is extremely wide but shallow; give it enough height for comfortable editing.
   - Hide or de-emphasize controls that cannot do anything until a sample is loaded.

8. **Slicer: replace the empty-state void**
   - The no-sample view leaves nearly the entire window blank.
   - Create one centered, bounded call-to-action: load audio, supported routes, and relevant shortcut.
   - Hide the empty slice sequence until audio exists, or show it as a compact preview rather than a one-row grid.
   - Once loaded, allocate substantial height to waveform slicing and the remaining area to sequence editing.

9. **Piano roll: add controller lanes**
   - The note grid uses space well, but the lowest pitch rows are often less valuable than velocity and expression editing.
   - Add a collapsible velocity lane at the bottom.
   - Consider optional automation or probability lanes later.
   - Compress the two-line toolbar and instruction row into one clearer control bar.
   - The mouse instructions are persistent visual noise and could move into contextual help or the status bar.
   - Strengthen octave boundaries and reduce emphasis on every semitone grid line.

10. **Automation: give the envelope more height**
    - The point editor consumes substantial height despite containing only two sliders and buttons.
    - Collapse it into a side inspector or compact bottom strip.
    - Let the graph occupy most of the screen.
    - Clarify the selected point using a more visible vertical/horizontal guide and compact value badge.
    - Avoid showing both the graph label and point-editor label with large separator bands.
    - Parameter tabs should support overflow or a searchable parameter control once more curves exist.

11. **Arrangement: improve clip legibility**
    - Clip labels and note previews compete for the same small vertical area.
    - Reserve a consistent label strip at the top of each clip.
    - Increase contrast between clip background, grid, and note preview.
    - Make selected clips more distinct than the current thin outline.
    - Reduce strong grid lines inside clips so content remains dominant.

12. **Drum grid: communicate step states**
    - Empty cells currently dominate the screen.
    - Differentiate normal hits, accented hits, selected cells, playback position, and off-grid cursor states.
    - Use beat subdivisions more clearly, with stronger beat boundaries and quieter minor divisions.
    - Add a compact legend only if those states cannot be understood visually.

13. **Instrument picker: use cards or a centered constrained list**
    - Four full-width rows create huge dead horizontal areas.
    - Use two-column cards at wide resolutions, each with icon, summary, and useful capability tags.
    - Alternatively, constrain the picker to a readable central width and reserve a side preview for the selected instrument.
    - Make selection more obvious than the narrow colored edge alone.

14. **Synth FX picker: avoid a four-row page**
    - The picker occupies only the top half despite having just four choices.
    - Use a two-by-two grid with short explanations and signal-role labels.
    - A small visualization for each option would make the choice more immediate.
    - Match the general FX picker's heading and help treatment for consistency.

15. **FX picker: reduce row height or add categories**
    - The long list is readable but visually repetitive.
    - Group effects by dynamics, tone, distortion, modulation, time, and utility.
    - Use the spare width for parameter summaries, CPU characteristics, or a small visual identity.
    - Consider two columns at this viewport width.
    - Selection color currently resembles category color; establish separate signals for category and focus.

16. **Automation parameter picker: stop centering tiny labels across full-width rows**
    - Full-width rows make names and ranges harder to scan.
    - Left-align parameter name and right-align range within a constrained content region.
    - Use two columns or a selected-parameter preview at wide widths.
    - Shorten displayed ranges using units: `%`, `st`, `dB`, `Hz`, and so on.
    - Make section headers sticky while scrolling.

17. **Preset picker: use horizontal space for discovery**
    - The list is effective vertically but wastes most of each row.
    - Add a fixed filter/category sidebar and use the remaining area for the preset list.
    - Show useful selected-preset metadata or synth macro summary on the right.
    - Reduce repeated `pad wstudio` text or move it into aligned columns.
    - The visible category header and per-row category label duplicate one another.
    - Give audition state a visible indicator rather than relying solely on the help bar.

18. **File browser: introduce columns**
    - Every row spans nearly the entire window while showing only a name and type.
    - Use columns for name, type, modified date, and perhaps size.
    - Constrain folder chevrons so they do not sit at the extreme right edge.
    - Add a compact location/breadcrumb row instead of spending a large header panel on the path.
    - Surface bookmarks in a sidebar when the window is wide.
    - Clarify the conflict between the top instruction strip and the much denser bottom status instructions.

19. **Remove the redundant `Workspace` strip**
    - Many views show a full-width row containing only "Workspace."
    - It consumes height without identifying the actual active workspace.
    - Replace it with the real view title, use it for breadcrumbs, or remove it.

20. **Unify view headers**
    - Some views include the transport header and `Workspace`; others begin directly with a small logo and title.
    - Define one hierarchy: global transport, view header, content, status bar.
    - Instrument editors, pickers, help, and FX views should feel like parts of the same application shell.

21. **Reduce persistent shortcut prose**
    - Shortcuts appear in headings, instructional rows, and the bottom status bar.
    - Keep the status bar contextual and move comprehensive instructions into help.
    - Retain only the two or three actions most relevant to the current focus.

22. **Make wide layouts responsive rather than stretched**
    - Lists should gain columns, sidebars, previews, or a maximum readable width.
    - Editors should give additional room to their central visual surface.
    - Controls should not remain pinned to the upper-left while blank space grows indefinitely.

23. **Standardize selection language**
    - Selection is represented variously by salmon fill, pale outline, colored left bar, tinted row, and colored text.
    - Define distinct treatments for focus, selected object, active/enabled state, category, and track identity.
    - Several current screens use the same accent for multiple meanings.

24. **Increase contrast of secondary text**
    - Descriptions, values, instructions, and inactive labels are often close to the background.
    - Raise contrast slightly for useful secondary information.
    - Make disabled values visibly disabled without making ordinary descriptions look disabled.

25. **Normalize section spacing**
    - Some views have large title/separator gaps while dense synth controls have almost none.
    - Establish consistent section header height, card padding, and control spacing.
    - Let spacing communicate grouping rather than relying on many horizontal rules.

26. **Use visualizations where they provide operational value**
    - FX, synth, sampler, automation, and master screens benefit from live graphs and meters.
    - Pickers and file lists benefit more from structure than decorative graphs.
    - Blank space should not automatically be filled; it should improve editing, monitoring, or navigation.

27. **Make empty states actionable**
    - Group FX, master FX, sampler, and slicer all need a common empty-state pattern.
    - Include one primary action, one concise explanation, and the relevant keyboard shortcut.
    - Remove repeated messages and controls that describe the same missing state.

28. **Revisit status-bar density**
    - Some status bars are concise; others contain nearly a manual's worth of commands.
    - Reserve the left side for current selection/value and the middle for a small contextual hint.
    - Keep the right-side view badge, since it provides useful orientation.

29. **Clarify the purpose of spectrum views**
    - The three screenshot names say `spectrum`, but no spectrum is visible.
    - If spectrum monitoring is intended, it should be the dominant use of empty FX space.
    - If these are simply FX-chain views, rename the screenshots/concept to avoid setting the wrong expectation.

30. **Preserve the strongest current layouts**
    - The piano roll, automation envelope, preset list, file browser, and help view already establish useful full-window structures.
    - Optimize these through density and hierarchy changes rather than wholesale redesign.
    - Focus the largest redesign effort on Tracks, Arrangement, FX, Synth, Sampler, Drum, and Slicer.

# GUI color identity

wstudio's GUI uses the **Patina** color system. Its visual signature is a
spruce-black workspace with an oxidized-green surface ladder, warm bone text,
and a coral focus signal. Color is semantic rather than decorative:

- coral marks focus and the primary interaction path;
- dusty rose marks modulation and automation;
- lichen marks rhythm, ranges, and timing;
- mineral teal marks audio and signal flow;
- red is reserved for destructive, error, mute, and playhead states.

The green cast must remain present from the deepest canvas through raised
controls. Replacing those surfaces with neutral charcoal and keeping only the
coral accent loses the identity.

## Category research

The palette deliberately avoids the most recognizable defaults in nearby
products: Bitwig's orange-on-charcoal signature, the blue and blue-gray chrome
common to Cubase, Ableton Live's neutral light/dark themes, and the multicolor
clips laid over charcoal in Logic Pro and FL Studio. REAPER is highly
themeable, so its default is less useful as a fixed identity reference.

Patina occupies a different space by tinting the whole structural hierarchy.
Track colors remain varied for scanning, but they are softened into the same
mineral family instead of becoming a generic rainbow.

## Palette

| Role | Hex | Use |
| --- | --- | --- |
| deepest surface | `#06100e` | canvas, title, modal dim base |
| application surface | `#0b1916` | windows and main panels |
| raised surface | `#12241f` | cards, frames, menus |
| hover surface | `#1b302a` | hover and low emphasis selection |
| active surface | `#284239` | active controls |
| strongest surface | `#38584d` | grabs and structural emphasis |
| primary text | `#f2eadb` | values and high emphasis labels |
| secondary text | `#c9c0ae` | normal labels |
| muted text | `#a6a595` | metadata |
| tertiary text | `#858b7e` | metadata labels and axis ticks |
| focus | `#f08777` | cursor, selected control, primary action |
| track cursor | `#f2eadb` | high-contrast track-row cursor outside the track rotation |
| modulation | `#d69ac0` | automation and modulation |
| rhythm | `#c9cf73` | drums, loops, timing, ranges |
| audio | `#71b9ac` | waveforms, samples, signal flow |
| danger | `#ff7779` | record, errors, mute, destructive action |
| routing | `#9d9dce` | voice and routing, the terminal's blue slot |

When extending the GUI, reuse these semantic roles before adding a color. New
colors should share Patina's moderate saturation and warm, weathered character.

## Patina Light specification

Patina Light is selectable with `wstudio.o.gui_theme = "patina_light"`. It
keeps the warm and weathered character of Patina without simply inverting the
dark theme. Paper and pale sage replace spruce-black, while every semantic
accent is darkened enough to remain legible on the light application surface.

| Role | Hex | Use |
| --- | --- | --- |
| deepest surface | `#dce6dd` | canvas and recessed regions |
| application surface | `#f3efe4` | windows and main panels |
| raised surface | `#ebe4d6` | cards, frames, menus |
| hover surface | `#d9e2d8` | hover and low emphasis selection |
| active surface | `#c7d8cd` | active controls |
| strongest surface | `#a9c0b2` | grabs and structural emphasis |
| primary text | `#17231f` | values and high emphasis labels |
| secondary text | `#34463f` | normal labels |
| muted text | `#48564e` | metadata |
| tertiary text | `#5d675e` | metadata labels and axis ticks |
| focus | `#a8453b` | cursor, selected control, primary action |
| focus soft | `#c16f60` | pressed controls and selection fills |
| track cursor | `#17231f` | high-contrast track-row cursor outside the track rotation |
| modulation | `#964778` | automation and modulation |
| rhythm | `#626918` | drums, loops, timing, ranges |
| audio | `#237067` | waveforms, samples, signal flow |
| danger | `#b7343f` | record, errors, mute, destructive action |
| routing | `#616090` | voice and routing, the terminal's blue slot |

Track fills are derived rather than listed: each of the six chromatic accents
above is mixed halfway into the canvas, which keeps a row tinted without
letting it compete with the note blocks drawn on top. Row labels are inked
with whichever of the two extremes contrasts better, so the same rotation
works in both polarities. Uncolored tracks use the normal surface ladder.

## Contrast floors

The palette is not tuned by eye alone. Every in-house theme is held to these
floors by tests in `src/theme_identity.zig` and `src/tui/theme.zig`, so a
future edit that dims a role fails the build rather than shipping:

- the four text tiers and the six chromatic accents clear **4.5:1** against
  both the application surface and the raised surface, which is WCAG 2.2
  SC 1.4.3 for body text at the two backgrounds they actually land on;
- `focus soft` clears **3:1** against the application surface. It fills slider
  grabs, active buttons and hovered separators, which are user interface
  components under SC 1.4.11 rather than text;
- every track fill clears **3:1** against at least one of the two inks, the
  same non-text floor, since a row label is drawn straight onto it;
- every ANSI slot the TUI can print text in clears **4.5:1** against the
  terminal background the theme sets. Slot 0 is a background and slot 8 is
  the conventional dim slot, so neither is held to a text floor.

Where a role had to move to clear a floor, it moved in OKLCh with its hue and
chroma held and only its lightness solved, and chroma reduced only as far as
the sRGB gamut required. That keeps a corrected color recognisably the same
color. The text tiers are additionally spaced evenly in OKLCh lightness, so
the four steps stay distinguishable instead of bunching against the floor.

APCA (the WCAG 3 draft's perceptual model) was used as a cross-check rather
than a gate: the corrected tiers land near Lc 60 for body text and above
Lc 45 for the accents, which are its published thresholds for those uses.

Imported palettes are exempt. They ship upstream's published values, several
of which do not clear these floors against their own backgrounds, and matching
upstream is the point of offering them.

## Research references

- [Ableton Live interface](https://www.ableton.com/en/live/learn-live/interface/)
- [Bitwig Studio user guide](https://www.bitwig.com/media/bitwig_userguide/pdf/Bitwig_Studio_User_Guide_English_G2qasDB.pdf)
- [Cubase features](https://www.steinberg.net/cubase/features/)
- [FL Studio interface](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/basics_interface.htm)
- [Logic Pro](https://www.apple.com/logic-pro/)
- [REAPER screenshots](https://www.reaper.fm/sshots.php)

Contrast and color-space references:

- [WCAG 2.2](https://www.w3.org/TR/WCAG22/), W3C Recommendation, for
  SC 1.4.3 Contrast (Minimum) and SC 1.4.11 Non-text Contrast.
- [APCA](https://git.apcacontrast.com/documentation/APCAeasyIntro), the
  perceptual contrast model drafted for WCAG 3, used as a cross-check.
- [A perceptual color space for image processing](https://bottosson.github.io/posts/oklab/),
  Björn Ottosson, for OKLab/OKLCh.
- [CSS Color Module Level 4](https://www.w3.org/TR/css-color-4/#gamut-mapping),
  W3C, for the chroma-reduction gamut mapping used when a solved lightness
  pushed a hue out of sRGB.

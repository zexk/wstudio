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
| muted text | `#9a9282` | metadata |
| disabled text | `#6f7569` | disabled and tertiary labels |
| focus | `#f08777` | cursor, selected control, primary action |
| modulation | `#d69ac0` | automation and modulation |
| rhythm | `#c9cf73` | drums, loops, timing, ranges |
| audio | `#71b9ac` | waveforms, samples, signal flow |
| danger | `#f06468` | record, errors, mute, destructive action |

When extending the GUI, reuse these semantic roles before adding a color. New
colors should share Patina's moderate saturation and warm, weathered character.

## Research references

- [Ableton Live interface](https://www.ableton.com/en/live/learn-live/interface/)
- [Bitwig Studio user guide](https://www.bitwig.com/media/bitwig_userguide/pdf/Bitwig_Studio_User_Guide_English_G2qasDB.pdf)
- [Cubase features](https://www.steinberg.net/cubase/features/)
- [FL Studio interface](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/basics_interface.htm)
- [Logic Pro](https://www.apple.com/logic-pro/)
- [REAPER screenshots](https://www.reaper.fm/sshots.php)

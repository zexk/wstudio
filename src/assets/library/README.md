# Bundled acoustic library

`vcsl/` contains a curated subset of VCSL Keys by Versilian Studios:

- Grand Piano, K
- Upright Piano, Y
- Harpsichord, Italian

Source: <https://versilian-studios.com/vcsl-keys/>, package published
2023-10-11. VCSL Keys is dedicated to the public domain under CC0 1.0. Exact
license text is in `vcsl/LICENSE`.

Only attack/sustain samples needed by wstudio's bounded SFZ reader are kept.
Release-trigger samples are omitted until playback supports release regions.
Original SFZ mappings and FLAC samples are otherwise unchanged.

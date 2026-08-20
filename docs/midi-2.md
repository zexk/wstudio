# MIDI 2.0 input

wstudio accepts Universal MIDI Packets through ALSA sequencer on Linux. It
requests a MIDI 2.0 sequencer client and enables ALSA conversion, so MIDI 1.0
and MIDI 2.0 sources can share one input port. Older kernels that reject UMP
client mode retain legacy MIDI input.

The protocol layer consumes packets by Message Type length: 32, 64, 96, or
128 bits. Unknown packet types and unsupported messages are skipped at their
declared boundary. Truncated packets wait for transport framing, and reserved
fields in recognized Channel Voice messages are rejected.

## Routed messages

- MIDI 1.0 Channel Voice UMP and MIDI 2.0 Channel Voice note on/off
- 16-bit note velocity, normalized only when entering DSP
- 32-bit CC and pitch bend
- 32-bit channel pressure and poly pressure
- 32-bit per-note pitch bend for built-in synth voices
- program and bank changes for hosted plugins
- MIDI 1.0 System Realtime UMP

CC, pressure, and pitch values retain MIDI 2.0 resolution through engine and
built-in synth. CLAP plugins using byte-stream MIDI receive a scaled MIDI 1.0
value at plugin boundary. VST3 MIDI mappings receive normalized values.

Groups and channels are decoded, but live input follows existing controller
routing: every message targets selected track. No channel or group filter is
configured yet.

## Deliberate boundaries

Per-note registered and assignable controllers, RPN, NRPN, SysEx7, SysEx8,
Mixed Data Set, Flex Data, and Stream messages are framed or decoded where
needed for safe traversal but have no DAW action yet. MIDI-CI Profiles and
Property Exchange require bidirectional endpoint and SysEx state that current
input-only controller subsystem does not own. wstudio does not advertise
those capabilities.

macOS CoreMIDI and Windows WinMM continue to receive OS-translated MIDI 1.0
byte streams. Native UMP resolution currently requires Linux ALSA.

## Protocol references

- [Universal MIDI Packet and MIDI 2.0 Protocol Specification](https://midi.org/universal-midi-packet-ump-and-midi-2-0-protocol-specification), M2-104-UM v1.1.2
- [MIDI 2.0 Bit Scaling and Resolution](https://midi.org/midi-2-0-bit-scaling-and-resolution)
- [ALSA UMP sequencer API](https://www.alsa-project.org/alsa-doc/alsa-lib/group___seq_middle.html)
- [Apple CoreMIDI MIDI 2.0 integration](https://developer.apple.com/documentation/coremidi/incorporating-midi-2-into-your-apps)


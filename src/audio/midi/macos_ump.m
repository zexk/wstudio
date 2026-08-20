#import <CoreMIDI/CoreMIDI.h>

typedef void (*WstudioMIDIUMPReadProc)(const UInt32 *words, UInt32 word_count, void *context);

OSStatus wstudio_midi_ump_input_port_create(
    MIDIClientRef client,
    CFStringRef name,
    WstudioMIDIUMPReadProc read,
    void *context,
    MIDIPortRef *port
) {
    if (@available(macOS 11.0, *)) {
        return MIDIInputPortCreateWithProtocol(client, name, kMIDIProtocol_2_0, port,
            ^(const MIDIEventList *events, void *source_context) {
                (void)source_context;
                const MIDIEventPacket *packet = &events->packet[0];
                for (UInt32 i = 0; i < events->numPackets; ++i) {
                    read(packet->words, packet->wordCount, context);
                    packet = MIDIEventPacketNext(packet);
                }
            });
    }
    return -1;
}

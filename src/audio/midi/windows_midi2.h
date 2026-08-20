#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*wstudio_midi2_message_callback)(void *context, const uint32_t *words, uint32_t word_count);
typedef void (*wstudio_midi2_device_callback)(void *context, const uint16_t *id, uint32_t id_len,
                                              const uint16_t *name, uint32_t name_len);

void *wstudio_midi2_open(const uint16_t *endpoint_id, uint32_t endpoint_id_len,
                         wstudio_midi2_message_callback callback, void *context);
void wstudio_midi2_close(void *handle);
int wstudio_midi2_list(wstudio_midi2_device_callback callback, void *context);

#ifdef __cplusplus
}
#endif

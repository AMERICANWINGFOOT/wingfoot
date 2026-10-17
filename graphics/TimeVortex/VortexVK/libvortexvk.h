/* libvortexvk.h -- VortexVK Vulkan compute renderer, QB64-PE interface */
#ifndef LIBVORTEXVK_H
#define LIBVORTEXVK_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Returns 1 on success, negative error code on failure.
   devIndex = -1 picks a discrete GPU automatically. */
int   vvk_init(int w, int h, int devIndex);

/* Spectrum band 0..15, value 0..1 */
void  vvk_set_band(int i, float v);

/* Renders one frame and copies w*h BGRA pixels to dst (QB64 image memory).
   Returns 1 on success. */
int   vvk_render(intptr_t dst, float t, float zpos, float bass, float mids,
                 float treb, float flash, float twist, float level);

/* Milliseconds for the last submit + wait + copy */
float vvk_ms(void);

/* Copies the GPU name (NUL-terminated) into out */
void  vvk_devname(char *out, int maxlen);

void  vvk_shutdown(void);

#ifdef __cplusplus
}
#endif
#endif

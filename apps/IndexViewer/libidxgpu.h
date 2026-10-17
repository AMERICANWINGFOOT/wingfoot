/* libidxgpu.h - CUDA star/quad renderer for IndexView.bas (QB64-PE 4.5.0)
 *
 * QB64 picks this header up automatically from DECLARE LIBRARY "./libidxgpu".
 * Types map to QB64 as:  int32_t = Long, double = Double, float = Single,
 * intptr_t = _Offset (ByVal).
 */
#ifndef LIBIDXGPU_H
#define LIBIDXGPU_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* devWanted < 0 picks the strongest card (env IDXGPU_DEVICE overrides).
   Returns 1 = ready, 0 = no usable CUDA device. */
int32_t idx_init(int32_t devWanted);

/* Copies "name (dev N, sm_XY)" into a caller buffer. */
void idx_device_name(intptr_t buf, int32_t bufLen);

/* Star unit vectors (doubles) and magnitudes (floats). n = 0 clears.
   Returns 1 = ok, 0 = out of GPU memory. */
int32_t idx_upload_stars(intptr_t px, intptr_t py, intptr_t pz, intptr_t pmag, int32_t n);

/* Quad table: nQuad * dimQ Longs, 1-based star numbers, 0 = invalid. */
int32_t idx_upload_quads(intptr_t pq, int32_t nQuad, int32_t dimQ);

/* Draws stars (and quads) into a w x h 32-bit ARGB buffer at fb, which
   starts transparent so the CPU-drawn grid shows through.
   mode 0 = all-sky Hammer-Aitoff, 1 = gnomonic close view.
   mx,my = mouse in buffer coordinates (< -50000 = no hover test).
   Returns hovered star (1-based), 0 = none, -1 = CUDA error. */
int32_t idx_render(int32_t mode,
                   double cx, double cy, double cz,
                   double ex, double ey, double ez,
                   double nx, double ny, double nz,
                   double zoom, double panX, double panY, double sky,
                   int32_t w, int32_t h, int32_t mx, int32_t my,
                   int32_t hasMag, float magLo, float magHi,
                   int32_t quadsOn, int32_t quadStep, intptr_t fb);

void idx_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif

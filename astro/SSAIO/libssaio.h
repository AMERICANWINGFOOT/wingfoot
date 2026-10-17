/*
 * libssaio.h - flat C shim over the QHY SDK (libqhyccd) for the
 * Orion StarShoot All-in-One (QHY5L-II underneath, 1618:0921 after
 * firmware load). QB64-PE never sees the qhyccd_handle.
 *
 * Buffers are passed as intptr_t so QB64's _OFFSET maps cleanly.
 * Return codes: 0 or positive = OK, negative = error (see ssaio.cpp).
 */
#ifndef LIBSSAIO_H
#define LIBSSAIO_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int    ssaio_init(void);                          /* returns camera count  */
int    ssaio_open(int index);                     /* 0 = OK               */
int    ssaio_model(intptr_t buf, int buflen);     /* copies model string  */
int    ssaio_width(void);
int    ssaio_height(void);
double ssaio_pixel_um(void);
int    ssaio_is_color(void);                      /* 0 mono, else bayer id */
int    ssaio_set_exposure_ms(double ms);
int    ssaio_set_gain(double gain);
int    ssaio_frame_bytes(void);
int    ssaio_grab(intptr_t buf, int buflen);      /* returns bytes copied */
void   ssaio_close(void);

#ifdef __cplusplus
}
#endif

#endif

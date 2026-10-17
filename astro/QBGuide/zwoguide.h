/* zwoguide.h - thin C shim between QB64-PE and the ZWO ASICamera2 SDK
   for QBGuide (a PHD2-style autoguider).  Only plain ints/doubles/pointers
   cross the boundary so QB64 Declare Library can call everything.

   Build (see build.sh):
     gcc -O2 -fPIC -shared zwoguide.c libASICamera2.a -o libzwoguide.so
         -lusb-1.0 -lpthread -lstdc++ -lm
*/
#ifndef ZWOGUIDE_H
#define ZWOGUIDE_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* camera discovery */
int    zg_count(void);                        /* number of ZWO cameras plugged in */
int    zg_name(int idx, char *buf, int len);  /* copy camera name into buf */

/* open / close (one guide camera at a time) */
int    zg_open(int idx);                      /* 0 = ok, <0 = error */
void   zg_close(void);
int    zg_is_open(void);

/* camera facts (valid after zg_open) */
int    zg_max_w(void);
int    zg_max_h(void);
double zg_pixel_um(void);
int    zg_is_color(void);
int    zg_has_st4(void);
int    zg_bit_depth(void);
int    zg_max_bin(void);
int    zg_gain_min(void);
int    zg_gain_max(void);
int    zg_gain_best(void);                    /* ZWO's "lowest read noise" gain */
double zg_temp_c(void);                       /* sensor temperature */

/* frame setup */
int    zg_set_format(int bin);                /* full frame, binned, RAW16; 0 = ok */
int    zg_frame_w(void);
int    zg_frame_h(void);
int    zg_set_gain(int gain);
int    zg_set_exposure_ms(int ms);

/* snap exposures (non-blocking, poll the status) */
int    zg_start_exposure(void);
int    zg_exp_status(void);                   /* 0 idle 1 working 2 done 3 failed */
void   zg_stop_exposure(void);
int    zg_read_frame(uintptr_t dest);         /* address of frame_w*frame_h unsigned 16-bit (QB64 _Offset) */

/* ST-4 guiding through the camera port.
   dir: 0 North, 1 South, 2 East, 3 West, -1 none.
   Both axes run at once in a background thread, so QB64 never blocks. */
int    zg_guide(int raDir, int raMs, int decDir, int decMs);
int    zg_guide_busy(void);
void   zg_guide_stop(void);

#ifdef __cplusplus
}
#endif
#endif

/* ssagguide.h - thin C shim between QB64-PE and the Orion StarShoot
   Autoguider (SSAG), using the open-source openssag driver that ships
   with PHD2 (thirdparty/openssag, (c) 2011 Eric J. Holmes, Orion).
   Same style of calls as zwoguide.h so QBGuide treats both alike.

   Build (see build.sh):
     g++ -O2 -fPIC -shared ssagguide.cpp openssag/openssag.cpp
         openssag/loader.cpp -Iopenssag -o libssagguide.so -lusb-1.0 -lpthread
*/
#ifndef SSAGGUIDE_H
#define SSAGGUIDE_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int    sg_count(void);                 /* 1 if an SSAG (or its firmware loader) is on USB */
int    sg_open(void);                  /* 0 = ok; loads the firmware if needed (up to ~10 s) */
void   sg_close(void);
int    sg_is_open(void);
int    sg_frame_w(void);               /* 1280 */
int    sg_frame_h(void);               /* 1024 */
int    sg_set_gain(int gain);          /* 1..15 */
int    sg_start_exposure(int ms);      /* runs in a background thread */
int    sg_exp_status(void);            /* 0 idle 1 working 2 done 3 failed */
void   sg_stop_exposure(void);
int    sg_read_frame(uintptr_t dest);  /* 1280*1024 unsigned 16-bit (8-bit data << 8) */
/* dir: 0 North, 1 South, 2 East, 3 West, -1 none (same as zwoguide) */
int    sg_guide(int raDir, int raMs, int decDir, int decMs);
int    sg_guide_busy(void);
void   sg_guide_stop(void);

#ifdef __cplusplus
}
#endif
#endif

/* qhy5guide.h - thin C shim between QB64-PE and the original QHY5
   guide camera (USB 16c0:296d, Micron MT9M001, 1280x1024, ST-4 port),
   ported from PHD2's cam_qhy5.cpp. Same style of calls as zwoguide.h.

   Build (see build.sh):
     gcc -O2 -fPIC -shared qhy5guide.c -Iopenssag -o libqhy5guide.so -lusb-1.0 -lpthread
*/
#ifndef QHY5GUIDE_H
#define QHY5GUIDE_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int    q5_count(void);                 /* 1 if a QHY5 (16c0:296d) is on USB */
int    q5_open(void);                  /* 0 = ok */
void   q5_close(void);
int    q5_is_open(void);
int    q5_frame_w(void);               /* 1280 */
int    q5_frame_h(void);               /* 1024 */
int    q5_set_gain(int gain);          /* 0..100 (%), like PHD2 */
int    q5_start_exposure(int ms);      /* runs in a background thread */
int    q5_exp_status(void);            /* 0 idle 1 working 2 done 3 failed */
void   q5_stop_exposure(void);
int    q5_read_frame(uintptr_t dest);  /* 1280*1024 unsigned 16-bit (8-bit data << 8) */
/* dir: 0 North, 1 South, 2 East, 3 West, -1 none (same as zwoguide).
   RA then Dec are sent one after the other, like PHD2. */
int    q5_guide(int raDir, int raMs, int decDir, int decMs);
int    q5_guide_busy(void);
void   q5_guide_stop(void);

#ifdef __cplusplus
}
#endif
#endif

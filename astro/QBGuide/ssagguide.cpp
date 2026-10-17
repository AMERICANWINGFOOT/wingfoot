/* ssagguide.cpp - QBGuide shim for the Orion StarShoot Autoguider.
   Wraps openssag (from PHD2's thirdparty folder) the way PHD2's
   cam_openssag.cpp does: libusb_init once, Connect(bootload) which
   uploads the firmware to a freshly plugged-in camera, blocking
   Expose (run here in a thread so QB64 never waits), and Guide()
   whose pulse timing is done by the camera itself. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <time.h>
#include <libusb.h>
#include "openssag.h"
#include "ssagguide.h"

using namespace OpenSSAG;

#define SG_W 1280
#define SG_H 1024
#define SG_VID 0x1856
#define SG_PID 0x0012          /* camera with firmware running */
#define SG_LOADER_PID 0x0011   /* fresh camera waiting for firmware */

static SSAG *g_cam = NULL;
static int g_usb = 0;
static int g_open = 0;

/* exposure thread */
static pthread_t g_th;
static volatile int g_state = 0;        /* 0 idle 1 working 2 done 3 failed */
static int g_expms = 1000;
static unsigned char *g_img = NULL;     /* SG_W*SG_H 8-bit */
static int g_thLive = 0;

/* guide pulse timing (the camera times the relays itself) */
static long g_guideEnd = 0;

static long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

static int usb_up(void)
{
    if (g_usb) return 0;
    if (libusb_init(NULL) != 0) return -1;
    g_usb = 1;
    return 0;
}

static int present(int pid)
{
    libusb_device **list;
    ssize_t n, i;
    int found = 0;
    n = libusb_get_device_list(NULL, &list);
    if (n < 0) return 0;
    for (i = 0; i < n; i++) {
        struct libusb_device_descriptor d;
        if (libusb_get_device_descriptor(list[i], &d) == 0)
            if (d.idVendor == SG_VID && d.idProduct == pid) found = 1;
    }
    libusb_free_device_list(list, 1);
    return found;
}

extern "C" int sg_count(void)
{
    if (usb_up()) return 0;
    if (g_open) return 1;
    return (present(SG_PID) || present(SG_LOADER_PID)) ? 1 : 0;
}

extern "C" int sg_open(void)
{
    if (g_open) return 0;
    if (usb_up()) return -1;
    if (!g_cam) g_cam = new SSAG();
    /* bootload = true: if only the loader is there, upload the firmware
       and wait for the camera to come back (openssag allows 10 s) */
    if (!g_cam->Connect(true, SG_VID, SG_LOADER_PID)) return -2;
    g_open = 1;
    g_state = 0;
    g_cam->SetGain(4);
    return 0;
}

extern "C" void sg_close(void)
{
    if (!g_open) return;
    if (g_thLive) { pthread_join(g_th, NULL); g_thLive = 0; }
    g_cam->Disconnect();
    g_open = 0;
    free(g_img); g_img = NULL;
}

extern "C" int sg_is_open(void) { return g_open; }
extern "C" int sg_frame_w(void) { return SG_W; }
extern "C" int sg_frame_h(void) { return SG_H; }

extern "C" int sg_set_gain(int gain)
{
    if (!g_open) return -1;
    if (gain < 1) gain = 1;
    if (gain > 15) gain = 15;
    g_cam->SetGain(gain);
    return 0;
}

static void *expose_thread(void *arg)
{
    struct raw_image *raw;
    (void)arg;
    raw = g_cam->Expose(g_expms);
    if (!raw) { g_state = 3; return NULL; }
    if (!g_img) g_img = (unsigned char *)malloc(SG_W * SG_H);
    if (g_img && raw->width == SG_W && raw->height == SG_H) {
        memcpy(g_img, raw->data, SG_W * SG_H);
        g_state = 2;
    } else {
        g_state = 3;
    }
    g_cam->FreeRawImage(raw);
    return NULL;
}

extern "C" int sg_start_exposure(int ms)
{
    if (!g_open) return -1;
    if (g_state == 1) return -2;
    if (g_thLive) { pthread_join(g_th, NULL); g_thLive = 0; }
    if (ms < 1) ms = 1;
    if (ms > 65000) ms = 65000;
    g_expms = ms;
    g_state = 1;
    if (pthread_create(&g_th, NULL, expose_thread, NULL) != 0) { g_state = 3; return -3; }
    g_thLive = 1;
    return 0;
}

extern "C" int sg_exp_status(void)
{
    if (!g_open) return 3;
    return g_state;
}

extern "C" void sg_stop_exposure(void)
{
    /* openssag's CancelExposure is marked "not tested" in the driver;
       the blocking read ends by itself after the exposure time */
    if (g_thLive && g_state != 1) { pthread_join(g_th, NULL); g_thLive = 0; }
    if (g_state != 1) g_state = 0;
}

extern "C" int sg_read_frame(uintptr_t destAddr)
{
    unsigned short *dest = (unsigned short *)destAddr;
    int i;
    if (!g_open || !dest) return -1;
    if (g_state != 2 || !g_img) return -2;
    for (i = 0; i < SG_W * SG_H; i++) dest[i] = (unsigned short)(g_img[i] << 8);
    g_state = 0;
    if (g_thLive) { pthread_join(g_th, NULL); g_thLive = 0; }
    return 0;
}

static int sg_dirbits(int d)
{
    switch (d) {
    case 0: return guide_north;
    case 1: return guide_south;
    case 2: return guide_east;
    case 3: return guide_west;
    default: return 0;
    }
}

extern "C" int sg_guide(int raDir, int raMs, int decDir, int decMs)
{
    int bits = 0, xms = 0, yms = 0, longest;
    if (!g_open) return -1;
    if (raDir >= 0 && raMs > 0)   { bits |= sg_dirbits(raDir);  xms = raMs; }
    if (decDir >= 0 && decMs > 0) { bits |= sg_dirbits(decDir); yms = decMs; }
    if (!bits) return 0;
    /* Guide(direction, yduration, xduration): x = RA (E/W), y = Dec (N/S) */
    g_cam->Guide(bits, yms, xms);
    longest = xms > yms ? xms : yms;
    g_guideEnd = now_ms() + longest + 10;   /* PHD2 waits duration + 10 ms */
    return 0;
}

extern "C" int sg_guide_busy(void)
{
    return now_ms() < g_guideEnd;
}

extern "C" void sg_guide_stop(void)
{
    /* the camera ends its own pulses; nothing to switch off here */
    g_guideEnd = 0;
}

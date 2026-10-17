/* qhy5guide.c - QBGuide shim for the original QHY5 guide camera.
   The USB commands below are taken from PHD2's src/cam_qhy5.cpp:
     0x13 + 0x14 (+ 0x16)  write the sensor registers (gain, rows)
     0x12                  start an exposure (duration in ms)
     bulk read on 0x82     1558 x 1050 bytes, cropped to 1280 x 1024
     0x10                  guide pulse (camera times it, max 2.54 s)
   Exposures and guide pulses run in background threads so QB64 never
   waits on the USB. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <time.h>
#include <libusb.h>
#include "qhy5guide.h"

#define QHY5_MATRIX_WIDTH  1558
#define QHY5_MATRIX_HEIGHT 1048
#define QHY5_BUFFER_SIZE   (QHY5_MATRIX_WIDTH * (QHY5_MATRIX_HEIGHT + 2))
#define QHY5_IMAGE_WIDTH   1280
#define QHY5_IMAGE_HEIGHT  1024
#define QHY5_VID 0x16c0
#define QHY5_PID 0x296d

#define STORE_WORD_BE(var, val) do { *(var) = ((val) >> 8) & 0xff; *((var) + 1) = (val) & 0xff; } while (0)

static const int gain_lut[74] = {
    0x000, 0x004, 0x005, 0x006, 0x007, 0x008, 0x009, 0x00A, 0x00B, 0x00C, 0x00D, 0x00E, 0x00F,
    0x010, 0x011, 0x012, 0x013, 0x014, 0x015, 0x016, 0x017, 0x018, 0x019, 0x01A, 0x01B, 0x01C,
    0x01D, 0x01E, 0x01F, 0x051, 0x052, 0x053, 0x054, 0x055, 0x056, 0x057, 0x058, 0x059, 0x05A,
    0x05B, 0x05C, 0x05D, 0x05E, 0x05F, 0x6CE, 0x6CF, 0x6D0, 0x6D1, 0x6D2, 0x6D3, 0x6D4, 0x6D5,
    0x6D6, 0x6D7, 0x6D8, 0x6D9, 0x6DA, 0x6DB, 0x6DC, 0x6DD, 0x6DE, 0x6DF, 0x6E0, 0x6E1, 0x6E2,
    0x6E3, 0x6E4, 0x6E5, 0x6E6, 0x6E7, 0x6FC, 0x6FD, 0x6FE, 0x6FF };

static libusb_device_handle *h = NULL;
static int g_usb = 0;
static unsigned char *raw = NULL;            /* QHY5_BUFFER_SIZE */
static unsigned char *img8 = NULL;           /* 1280 x 1024 */
static int g_gain = 80, g_lastGain = -1, g_firstTime = 1;

/* USB is used by both threads: one lock so they never overlap */
static pthread_mutex_t usbLock = PTHREAD_MUTEX_INITIALIZER;

static pthread_t expTh;
static int expLive = 0;
static volatile int expState = 0;           /* 0 idle 1 working 2 done 3 failed */
static int expMs = 1000;

static pthread_t gTh;
static volatile int gBusy = 0, gAbort = 0;
static int gRaDir, gRaMs, gDecDir, gDecMs;

static int usb_up(void)
{
    if (g_usb) return 0;
    if (libusb_init(NULL) != 0) return -1;
    g_usb = 1;
    return 0;
}

int q5_count(void)
{
    libusb_device **list;
    ssize_t n, i;
    int found = 0;
    if (h) return 1;
    if (usb_up()) return 0;
    n = libusb_get_device_list(NULL, &list);
    if (n < 0) return 0;
    for (i = 0; i < n; i++) {
        struct libusb_device_descriptor d;
        if (libusb_get_device_descriptor(list[i], &d) == 0 &&
            d.idVendor == QHY5_VID && d.idProduct == QHY5_PID) found = 1;
    }
    libusb_free_device_list(list, 1);
    return found;
}

int q5_open(void)
{
    if (h) return 0;
    if (usb_up()) return -1;
    h = libusb_open_device_with_vid_pid(NULL, QHY5_VID, QHY5_PID);
    if (!h) return -2;                       /* not found, or no USB permission */
    if (libusb_kernel_driver_active(h, 0) == 1) libusb_detach_kernel_driver(h, 0);
    libusb_set_configuration(h, 1);
    if (libusb_claim_interface(h, 0) != 0) { libusb_close(h); h = NULL; return -3; }
    raw = (unsigned char *)malloc(QHY5_BUFFER_SIZE);
    img8 = (unsigned char *)malloc(QHY5_IMAGE_WIDTH * QHY5_IMAGE_HEIGHT);
    if (!raw || !img8) { q5_close(); return -4; }
    expState = 0;
    g_lastGain = -1;
    g_firstTime = 1;
    return 0;
}

void q5_close(void)
{
    if (expLive) { pthread_join(expTh, NULL); expLive = 0; }
    q5_guide_stop();
    if (h) {
        libusb_release_interface(h, 0);
        libusb_close(h);
        h = NULL;
    }
    free(raw); raw = NULL;
    free(img8); img8 = NULL;
}

int q5_is_open(void) { return h != NULL; }
int q5_frame_w(void) { return QHY5_IMAGE_WIDTH; }
int q5_frame_h(void) { return QHY5_IMAGE_HEIGHT; }

int q5_set_gain(int gain)
{
    if (gain < 0) gain = 0;
    if (gain > 100) gain = 100;
    g_gain = gain;
    return 0;
}

/* register setup - same sequence and checks as PHD2's Capture() */
static void write_registers(void)
{
    unsigned char reg[19];
    int op_height = QHY5_IMAGE_HEIGHT, offset, value, index, gain, gain_val;
    op_height -= (op_height % 4);
    offset = (QHY5_MATRIX_HEIGHT - op_height) / 2;
    index = (QHY5_MATRIX_WIDTH * (op_height + 26)) >> 16;
    value = (QHY5_MATRIX_WIDTH * (op_height + 26)) & 0xffff;
    gain = (int)(73. * (g_gain / 100.));
    if (gain > 73) gain = 73;
    if (gain < 0) gain = 0;
    gain_val = gain_lut[gain];
    STORE_WORD_BE(reg + 0, gain_val);
    STORE_WORD_BE(reg + 2, gain_val);
    STORE_WORD_BE(reg + 4, gain_val);
    STORE_WORD_BE(reg + 6, gain_val);
    STORE_WORD_BE(reg + 8, offset);
    STORE_WORD_BE(reg + 10, 0);
    STORE_WORD_BE(reg + 12, op_height - 1);
    STORE_WORD_BE(reg + 14, 0x0521);
    STORE_WORD_BE(reg + 16, op_height + 25);
    reg[18] = 0xcc;
    if (libusb_control_transfer(h, 0x42, 0x13, value, index, reg, sizeof(reg), 5000)) {
        usleep(2000);
        if (libusb_control_transfer(h, 0x42, 0x14, 0x31a5, 0, reg, 0, 5000)) {
            usleep(1000);
            if (libusb_control_transfer(h, 0x42, 0x16, 0, g_firstTime, reg, 0, 5000))
                g_firstTime = 0;
        }
    }
    g_lastGain = g_gain;
}

static void *expose_thread(void *arg)
{
    unsigned char buffer[2];
    int ret, got = 0, y;
    (void)arg;
    pthread_mutex_lock(&usbLock);
    if (g_gain != g_lastGain) write_registers();
    buffer[0] = 0; buffer[1] = 100;
    libusb_control_transfer(h, 0xc2, 0x12, expMs & 0xffff, expMs >> 16, buffer, 2, 5000);
    pthread_mutex_unlock(&usbLock);

    usleep((useconds_t)expMs * 1000);        /* exposure running in the camera */

    pthread_mutex_lock(&usbLock);
    ret = libusb_bulk_transfer(h, 0x82, raw, QHY5_BUFFER_SIZE, &got, 20000);
    pthread_mutex_unlock(&usbLock);
    if (ret < 0 || got != QHY5_BUFFER_SIZE) { expState = 3; return NULL; }
    /* crop the 1558-wide matrix to 1280 x 1024, starting 20 columns in */
    for (y = 0; y < QHY5_IMAGE_HEIGHT; y++)
        memcpy(img8 + y * QHY5_IMAGE_WIDTH, raw + QHY5_MATRIX_WIDTH * y + 20, QHY5_IMAGE_WIDTH);
    expState = 2;
    return NULL;
}

int q5_start_exposure(int ms)
{
    if (!h) return -1;
    if (expState == 1) return -2;
    if (expLive) { pthread_join(expTh, NULL); expLive = 0; }
    if (ms < 1) ms = 1;
    expMs = ms;
    expState = 1;
    if (pthread_create(&expTh, NULL, expose_thread, NULL) != 0) { expState = 3; return -3; }
    expLive = 1;
    return 0;
}

int q5_exp_status(void) { return h ? expState : 3; }

void q5_stop_exposure(void)
{
    /* the QHY5 has no abort command: a running exposure finishes by itself */
    if (expLive && expState != 1) { pthread_join(expTh, NULL); expLive = 0; }
    if (expState != 1) expState = 0;
}

int q5_read_frame(uintptr_t destAddr)
{
    unsigned short *dest = (unsigned short *)destAddr;
    int i;
    if (!h || !dest) return -1;
    if (expState != 2) return -2;
    for (i = 0; i < QHY5_IMAGE_WIDTH * QHY5_IMAGE_HEIGHT; i++) dest[i] = (unsigned short)(img8[i] << 8);
    expState = 0;
    if (expLive) { pthread_join(expTh, NULL); expLive = 0; }
    return 0;
}

/* one pulse, as in PHD2's ST4PulseGuideScope */
static void pulse(int dir, int ms)
{
    int regv = 0;
    int32_t dur[2] = { -1, -1 };
    if (dir < 0 || ms <= 0) return;
    if (ms > 2540) ms = 2540;               /* camera maximum */
    switch (dir) {
    case 3: regv = 0x80; dur[0] = ms; break; /* West  */
    case 0: regv = 0x40; dur[1] = ms; break; /* North */
    case 1: regv = 0x20; dur[1] = ms; break; /* South */
    case 2: regv = 0x10; dur[0] = ms; break; /* East  */
    default: return;
    }
    pthread_mutex_lock(&usbLock);
    libusb_control_transfer(h, 0x42, 0x10, 0, regv, (unsigned char *)dur, sizeof(dur), 5000);
    pthread_mutex_unlock(&usbLock);
    {   /* wait it out (the camera ends the pulse itself) */
        int t = 0;
        while (t < ms + 10 && !gAbort) { usleep(5000); t += 5; }
    }
}

static void *guide_thread(void *arg)
{
    (void)arg;
    pulse(gRaDir, gRaMs);
    if (!gAbort) pulse(gDecDir, gDecMs);
    gBusy = 0;
    return NULL;
}

int q5_guide(int raDir, int raMs, int decDir, int decMs)
{
    if (!h) return -1;
    if (gBusy) return -2;
    gRaDir = raDir; gRaMs = raMs; gDecDir = decDir; gDecMs = decMs;
    gAbort = 0;
    gBusy = 1;
    if (pthread_create(&gTh, NULL, guide_thread, NULL) != 0) { gBusy = 0; return -3; }
    pthread_detach(gTh);
    return 0;
}

int q5_guide_busy(void) { return gBusy; }

void q5_guide_stop(void)
{
    int i;
    gAbort = 1;
    for (i = 0; i < 300 && gBusy; i++) usleep(10000);
}

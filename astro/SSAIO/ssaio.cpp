/*
 * ssaio.cpp - QHY SDK shim for the Orion StarShoot All-in-One
 *
 * Build (see build.sh):
 *   g++ -O2 -fPIC -shared ssaio.cpp -o libssaio.so -I/usr/local/include
 *       -L/usr/local/lib -lqhyccd -Wl,-rpath,/usr/local/lib
 *
 * Error codes:
 *   -1 SDK not initialised / camera not open
 *   -2 GetQHYCCDId failed (bad index)  /  grab: out of memory
 *   -3 OpenQHYCCD failed               /  grab: exposure start failed
 *   -4 SetQHYCCDStreamMode failed      /  grab: frame read failed
 *   -5 InitQHYCCD failed               /  grab: caller buffer too small
 *   -6 GetQHYCCDChipInfo failed
 *   -7 SetQHYCCDParam failed
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "qhyccd.h"
#include "libssaio.h"

static qhyccd_handle *g_cam = NULL;
static char     g_id[64];
static uint32_t g_w = 0, g_h = 0, g_bpp = 8;
static double   g_pix = 0.0;
static int      g_color = 0;
static int      g_inited = 0;
static unsigned char *g_tmp = NULL;
static uint32_t g_tmplen = 0;

int ssaio_init(void)
{
    if (!g_inited) {
        if (InitQHYCCDResource() != QHYCCD_SUCCESS) return -1;
        g_inited = 1;
    }
    return (int)ScanQHYCCD();
}

int ssaio_open(int index)
{
    double chipw, chiph, pw, ph;
    uint32_t iw, ih, bpp, r;

    if (!g_inited) return -1;
    if (g_cam) return 0;

    memset(g_id, 0, sizeof(g_id));
    if (GetQHYCCDId((uint32_t)index, g_id) != QHYCCD_SUCCESS) return -2;

    g_cam = OpenQHYCCD(g_id);
    if (!g_cam) return -3;

    /* 0 = single-frame mode */
    if (SetQHYCCDStreamMode(g_cam, 0) != QHYCCD_SUCCESS) return -4;
    if (InitQHYCCD(g_cam) != QHYCCD_SUCCESS) return -5;

    if (GetQHYCCDChipInfo(g_cam, &chipw, &chiph, &iw, &ih,
                          &pw, &ph, &bpp) != QHYCCD_SUCCESS) return -6;

    /* CAM_COLOR returns the bayer pattern id, or QHYCCD_ERROR on mono */
    r = IsQHYCCDControlAvailable(g_cam, CAM_COLOR);
    g_color = (r == QHYCCD_ERROR) ? 0 : (int)r;

    /* raw frames: we want the bayer data, not the SDK's debayer */
    if (g_color) SetQHYCCDDebayerOnOff(g_cam, false);

    SetQHYCCDBinMode(g_cam, 1, 1);
    SetQHYCCDResolution(g_cam, 0, 0, iw, ih);

    /* 8-bit transfer keeps the first test simple */
    if (IsQHYCCDControlAvailable(g_cam, CONTROL_TRANSFERBIT) == QHYCCD_SUCCESS)
        SetQHYCCDBitsMode(g_cam, 8);

    g_w = iw;
    g_h = ih;
    g_bpp = 8;
    g_pix = pw;

    /* safe starting values: 10 ms, gain 10 */
    SetQHYCCDParam(g_cam, CONTROL_EXPOSURE, 10000.0);
    SetQHYCCDParam(g_cam, CONTROL_GAIN, 10.0);
    return 0;
}

int ssaio_model(intptr_t buf, int buflen)
{
    char model[64];
    char *out = (char *)buf;

    if (!g_inited || !out || buflen < 1) return -1;
    memset(model, 0, sizeof(model));
    if (GetQHYCCDModel(g_id, model) != QHYCCD_SUCCESS)
        strcpy(model, g_id);          /* fall back to the camera id */
    strncpy(out, model, (size_t)buflen - 1);
    out[buflen - 1] = 0;
    return 0;
}

int    ssaio_width(void)    { return (int)g_w; }
int    ssaio_height(void)   { return (int)g_h; }
double ssaio_pixel_um(void) { return g_pix; }
int    ssaio_is_color(void) { return g_color; }

int ssaio_set_exposure_ms(double ms)
{
    if (!g_cam) return -1;
    /* SDK takes microseconds */
    if (SetQHYCCDParam(g_cam, CONTROL_EXPOSURE, ms * 1000.0) != QHYCCD_SUCCESS)
        return -7;
    return 0;
}

int ssaio_set_gain(double gain)
{
    if (!g_cam) return -1;
    if (SetQHYCCDParam(g_cam, CONTROL_GAIN, gain) != QHYCCD_SUCCESS)
        return -7;
    return 0;
}

int ssaio_frame_bytes(void)
{
    return (int)(g_w * g_h * ((g_bpp + 7) / 8));
}

int ssaio_grab(intptr_t buf, int buflen)
{
    uint32_t w, h, bpp, ch, need, bytes, r;
    unsigned char *out = (unsigned char *)buf;

    if (!g_cam || !out) return -1;

    /* the SDK can write up to MemLength, which is more than w*h,
       so read into our own buffer and copy the image part out */
    need = GetQHYCCDMemLength(g_cam);
    if (need > g_tmplen) {
        free(g_tmp);
        g_tmp = (unsigned char *)malloc(need);
        if (!g_tmp) { g_tmplen = 0; return -2; }
        g_tmplen = need;
    }

    /* returns QHYCCD_SUCCESS or QHYCCD_READ_DIRECTLY when OK */
    r = ExpQHYCCDSingleFrame(g_cam);
    if (r == QHYCCD_ERROR) return -3;

    if (GetQHYCCDSingleFrame(g_cam, &w, &h, &bpp, &ch, g_tmp) != QHYCCD_SUCCESS)
        return -4;

    bytes = w * h * ch * ((bpp + 7) / 8);
    if ((int)bytes > buflen) return -5;

    memcpy(out, g_tmp, bytes);
    g_w = w;
    g_h = h;
    g_bpp = bpp;
    return (int)bytes;
}

void ssaio_close(void)
{
    if (g_cam) {
        CloseQHYCCD(g_cam);
        g_cam = NULL;
    }
    if (g_inited) {
        ReleaseQHYCCDResource();
        g_inited = 0;
    }
    free(g_tmp);
    g_tmp = NULL;
    g_tmplen = 0;
}

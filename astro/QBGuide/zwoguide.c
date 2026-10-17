/* zwoguide.c - thin C shim between QB64-PE and the ZWO ASICamera2 SDK
   for QBGuide.  The camera handling follows PHD2's cam_zwo.cpp:
   snap mode, RAW16, bandwidth at minimum, white balance at unity,
   ASIGetGainOffset for the lowest-read-noise gain, and
   ASIPulseGuideOn/Off for ST-4 pulses.
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <time.h>
#include "ASICamera2.h"
#include "zwoguide.h"

static int  g_open = 0;
static int  g_id = -1;
static ASI_CAMERA_INFO g_info;
static int  g_bin = 1;
static int  g_fw = 0, g_fh = 0;
static int  g_gmin = 0, g_gmax = 0, g_gbest = 0;
static unsigned char *g_buf = NULL;
static long g_bufsize = 0;
static int  g_expstate = 0;   /* our own copy: 0 idle 1 working */

/* ---------- discovery ---------- */

int zg_count(void)
{
    return ASIGetNumOfConnectedCameras();
}

int zg_name(int idx, char *buf, int len)
{
    ASI_CAMERA_INFO info;
    if (len < 1) return -1;
    buf[0] = 0;
    if (ASIGetCameraProperty(&info, idx) != ASI_SUCCESS) return -1;
    strncpy(buf, info.Name, len - 1);
    buf[len - 1] = 0;
    return 0;
}

/* ---------- open / close ---------- */

int zg_open(int idx)
{
    int n, i, maxb;
    if (g_open) zg_close();
    if (ASIGetCameraProperty(&g_info, idx) != ASI_SUCCESS) return -1;
    g_id = g_info.CameraID;
    if (ASIOpenCamera(g_id) != ASI_SUCCESS) return -2;
    if (ASIInitCamera(g_id) != ASI_SUCCESS) { ASICloseCamera(g_id); return -3; }

    g_gmin = 0; g_gmax = 0; g_gbest = 0;
    if (ASIGetNumOfControls(g_id, &n) == ASI_SUCCESS) {
        for (i = 0; i < n; i++) {
            ASI_CONTROL_CAPS caps;
            if (ASIGetControlCaps(g_id, i, &caps) != ASI_SUCCESS) continue;
            switch (caps.ControlType) {
            case ASI_GAIN:
                g_gmin = (int)caps.MinValue; g_gmax = (int)caps.MaxValue;
                break;
            case ASI_BANDWIDTHOVERLOAD:
                /* PHD2 sets bandwidth to minimum for reliable downloads */
                ASISetControlValue(g_id, ASI_BANDWIDTHOVERLOAD, caps.MinValue, ASI_FALSE);
                break;
            case ASI_WB_R:
            case ASI_WB_B:
                if (caps.IsWritable) ASISetControlValue(g_id, caps.ControlType, 50, ASI_FALSE);
                break;
            default:
                break;
            }
        }
    }
    {
        int o1, o2, glrn, o3;
        if (ASIGetGainOffset(g_id, &o1, &o2, &glrn, &o3) == ASI_SUCCESS) g_gbest = glrn;
        else g_gbest = (g_gmin + g_gmax) / 2;
    }

    maxb = 1;
    for (i = 0; i < 16 && g_info.SupportedBins[i]; i++)
        if (g_info.SupportedBins[i] > maxb) maxb = g_info.SupportedBins[i];
    (void)maxb;

    g_bufsize = (long)g_info.MaxWidth * (long)g_info.MaxHeight * 2;
    free(g_buf);
    g_buf = (unsigned char *)malloc(g_bufsize);
    if (!g_buf) { ASICloseCamera(g_id); return -4; }

    ASIStopVideoCapture(g_id);
    ASIStopExposure(g_id);
    g_open = 1;
    g_expstate = 0;
    if (zg_set_format(1) != 0) { zg_close(); return -5; }
    return 0;
}

void zg_close(void)
{
    if (!g_open) return;
    zg_guide_stop();
    ASIStopExposure(g_id);
    ASICloseCamera(g_id);
    free(g_buf); g_buf = NULL;
    g_open = 0;
    g_id = -1;
}

int zg_is_open(void) { return g_open; }

/* ---------- facts ---------- */

int    zg_max_w(void)     { return g_open ? (int)g_info.MaxWidth : 0; }
int    zg_max_h(void)     { return g_open ? (int)g_info.MaxHeight : 0; }
double zg_pixel_um(void)  { return g_open ? g_info.PixelSize : 0.0; }
int    zg_is_color(void)  { return g_open ? (g_info.IsColorCam != ASI_FALSE) : 0; }
int    zg_has_st4(void)   { return g_open ? (g_info.ST4Port != ASI_FALSE) : 0; }
int    zg_bit_depth(void) { return g_open ? g_info.BitDepth : 0; }
int    zg_gain_min(void)  { return g_gmin; }
int    zg_gain_max(void)  { return g_gmax; }
int    zg_gain_best(void) { return g_gbest; }

int zg_max_bin(void)
{
    int i, m = 1;
    if (!g_open) return 1;
    for (i = 0; i < 16 && g_info.SupportedBins[i]; i++)
        if (g_info.SupportedBins[i] > m) m = g_info.SupportedBins[i];
    return m;
}

double zg_temp_c(void)
{
    long v = 0; ASI_BOOL a;
    if (!g_open) return 0.0;
    if (ASIGetControlValue(g_id, ASI_TEMPERATURE, &v, &a) != ASI_SUCCESS) return 0.0;
    return v / 10.0;
}

/* ---------- frame setup ---------- */

int zg_set_format(int bin)
{
    int w, h, i, ok = 0;
    if (!g_open) return -1;
    for (i = 0; i < 16 && g_info.SupportedBins[i]; i++)
        if (g_info.SupportedBins[i] == bin) ok = 1;
    if (!ok) bin = 1;
    w = (int)g_info.MaxWidth / bin;
    h = (int)g_info.MaxHeight / bin;
    /* SDK rule: width multiple of 8, height multiple of 2 */
    w -= w % 8;
    h -= h % 2;
    ASIStopExposure(g_id);
    if (ASISetROIFormat(g_id, w, h, bin, ASI_IMG_RAW16) != ASI_SUCCESS) return -2;
    /* PHD2 note: always follow SetROIFormat with SetStartPos */
    ASISetStartPos(g_id, 0, 0);
    g_bin = bin; g_fw = w; g_fh = h;
    g_expstate = 0;
    return 0;
}

int zg_frame_w(void) { return g_fw; }
int zg_frame_h(void) { return g_fh; }

int zg_set_gain(int gain)
{
    if (!g_open) return -1;
    if (gain < g_gmin) gain = g_gmin;
    if (gain > g_gmax) gain = g_gmax;
    return ASISetControlValue(g_id, ASI_GAIN, gain, ASI_FALSE) == ASI_SUCCESS ? 0 : -2;
}

int zg_set_exposure_ms(int ms)
{
    if (!g_open) return -1;
    if (ms < 1) ms = 1;
    return ASISetControlValue(g_id, ASI_EXPOSURE, (long)ms * 1000L, ASI_FALSE) == ASI_SUCCESS ? 0 : -2;
}

/* ---------- exposures ---------- */

int zg_start_exposure(void)
{
    if (!g_open) return -1;
    if (ASIStartExposure(g_id, ASI_FALSE) != ASI_SUCCESS) return -2;
    g_expstate = 1;
    return 0;
}

int zg_exp_status(void)
{
    ASI_EXPOSURE_STATUS s;
    if (!g_open) return 3;
    if (ASIGetExpStatus(g_id, &s) != ASI_SUCCESS) return 3;
    switch (s) {
    case ASI_EXP_IDLE:    return 0;
    case ASI_EXP_WORKING: return 1;
    case ASI_EXP_SUCCESS: return 2;
    default:              return 3;
    }
}

void zg_stop_exposure(void)
{
    if (g_open) ASIStopExposure(g_id);
    g_expstate = 0;
}

int zg_read_frame(uintptr_t destAddr)
{
    long n;
    void *dest = (void *)destAddr;
    if (!g_open || !dest) return -1;
    n = (long)g_fw * (long)g_fh * 2;
    if (n > g_bufsize) return -2;
    if (ASIGetDataAfterExp(g_id, g_buf, n) != ASI_SUCCESS) { g_expstate = 0; return -3; }
    memcpy(dest, g_buf, n);   /* RAW16 little-endian = QB64 _Unsigned Integer */
    g_expstate = 0;
    return 0;
}

/* ---------- ST-4 guide pulses ---------- */

static pthread_mutex_t g_glock = PTHREAD_MUTEX_INITIALIZER;
static volatile int g_gbusy = 0;
static volatile int g_gabort = 0;
static int g_raDir, g_raMs, g_decDir, g_decMs;

static long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

static void *guide_thread(void *arg)
{
    long t0, t;
    int raOn = 0, decOn = 0;
    (void)arg;
    t0 = now_ms();
    if (g_raDir >= 0 && g_raMs > 0)   { ASIPulseGuideOn(g_id, (ASI_GUIDE_DIRECTION)g_raDir);  raOn = 1; }
    if (g_decDir >= 0 && g_decMs > 0) { ASIPulseGuideOn(g_id, (ASI_GUIDE_DIRECTION)g_decDir); decOn = 1; }
    while (raOn || decOn) {
        usleep(1000);
        t = now_ms() - t0;
        if (raOn && (t >= g_raMs || g_gabort))   { ASIPulseGuideOff(g_id, (ASI_GUIDE_DIRECTION)g_raDir);  raOn = 0; }
        if (decOn && (t >= g_decMs || g_gabort)) { ASIPulseGuideOff(g_id, (ASI_GUIDE_DIRECTION)g_decDir); decOn = 0; }
    }
    pthread_mutex_lock(&g_glock);
    g_gbusy = 0;
    pthread_mutex_unlock(&g_glock);
    return NULL;
}

int zg_guide(int raDir, int raMs, int decDir, int decMs)
{
    pthread_t th;
    if (!g_open) return -1;
    pthread_mutex_lock(&g_glock);
    if (g_gbusy) { pthread_mutex_unlock(&g_glock); return -2; }
    g_gbusy = 1;
    g_gabort = 0;
    pthread_mutex_unlock(&g_glock);
    g_raDir = raDir; g_raMs = raMs; g_decDir = decDir; g_decMs = decMs;
    if (pthread_create(&th, NULL, guide_thread, NULL) != 0) { g_gbusy = 0; return -3; }
    pthread_detach(th);
    return 0;
}

int zg_guide_busy(void) { return g_gbusy; }

void zg_guide_stop(void)
{
    int i;
    if (!g_gbusy) return;
    g_gabort = 1;
    for (i = 0; i < 200 && g_gbusy; i++) usleep(1000);
    /* belt and braces: make sure every relay is off */
    if (g_open) {
        for (i = 0; i < 4; i++) ASIPulseGuideOff(g_id, (ASI_GUIDE_DIRECTION)i);
    }
}

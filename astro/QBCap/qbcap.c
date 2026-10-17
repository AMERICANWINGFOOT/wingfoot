/*
 * qbcap.c  -  capture core for QBCap (QB64-PE front end)
 * Step 1: camera open/controls, background video capture thread,
 *         triple-buffered frames, stretched preview drawn straight into
 *         a QB64 32-bit image (_MemImage), histogram, stats.
 * Step 2: recording - RAM ring buffer fed by the capture thread, drained
 *         by a writer thread to SER (one file) or FITS (one file per
 *         frame); snapshot to FITS; preview white balance.
 * Step 3: ZWO EFW filter wheel (libEFWFilter.so).
 * Step 4: master dark / flat capture, save/load, applied to the preview.
 * Step 5: sharpness score per frame (CUDA via libqbgpu.so, or CPU) and
 *         lucky imaging - record only the sharpest frames.
 * Step 6: live stacking - calibrate, find stars, align (shift + rotation),
 *         mean or sigma-clip accumulate (GPU or CPU), 32-bit FITS save.
 * Step 7: plate solving - our own star list handed to astrometry.net's
 *         solve-field (run in the background), result + solved FITS.
 * Step 8: polar alignment - two solves with an RA turn between give the
 *         mount axis; live solves then show the error while adjusting.
 * Step 9: QHY PoleMaster as a second camera for polar alignment
 *         (libqhyccd.so loaded at run time).
 * Step 11: autoguiding through the camera's ST-4 port (guide mode: a second
 *         QBCap runs the guide camera; pause / resume / dither over local UDP).
 * Step 10: mount control (Sky-Watcher / SynScan motor protocol over WiFi
 *         or USB): jog, tracking, positions, stall + lost-link stops.
 * Step 13: standard Linux USB camera (V4L2) as a main camera - webcams and
 *         cheap planetary cameras that give raw 8-bit Bayer or mono frames
 *         (e.g. Microdia 0c45:6242 SN9C201 + MI1310). Uses the kernel's
 *         video API only, so no extra library. 8-bit, full frame.
 * Step 12: Orion StarShoot G3 as a main camera (libssg3.so loaded at run
 *         time, like the PoleMaster). No video mode: the capture thread
 *         loops expose -> download. 16-bit, full frame, bin 1. If
 *         libssg3.so is missing, the G3 just isn't available - ZWO
 *         cameras work exactly as before.
 * Step 14: QHY camera as a main camera, e.g. the Orion StarShoot
 *         All-in-One (a QHY5LII-C inside). Uses the same libqhyccd.so the
 *         PoleMaster loads (dlopen). Single-frame loop like the G3, 8- or
 *         16-bit, full frame, bin 1. A PoleMaster is never picked as the
 *         main camera, and the PoleMaster code never grabs the main QHY.
 *
 * All exported functions use plain int / char* / void* so QB64's
 * Long (32-bit) and _Offset map cleanly. (C "long" is 64-bit on Linux,
 * so it never appears in this API.)
 *
 * Build (OptiPlex, RTX 3050 - CUDA part comes later):
 *   gcc -O2 -shared -fPIC -o libqbcap.so qbcap.c \
 *       -L. -lASICamera2 -lEFWFilter -l:libudev.so.1 -lpthread -lm -Wl,-rpath,'$ORIGIN'
 *   (libEFWFilter.so uses libudev but does not declare it, so it is linked here)
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>
#include <stdint.h>
#include <errno.h>
#include <sys/stat.h>
#include <dlfcn.h>
#include <dirent.h>
#include <stdbool.h>
#include <signal.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <poll.h>
#include <linux/videodev2.h>
#include "ASICamera2.h"
#include "EFW_filter.h"

#define QC_VERSION 15
#define REC_MAX_SLOTS 256
#define REC_MAX_BYTES (1024ULL * 1024 * 1024)   /* ring buffer RAM cap: 1 GB */

/* ------------------------------------------------------------------ */
/* recording state                                                     */
/* ------------------------------------------------------------------ */
typedef struct {
    pthread_mutex_t mx;
    pthread_cond_t  cv;
    pthread_t thr;
    int      threadLive;          /* writer thread exists and needs joining */
    volatile int active;          /* 1 while recording or still draining */
    int      accepting;           /* capture thread may push frames */
    int      format;              /* 0 = SER, 1 = FITS sequence */
    int      nslots;
    uint8_t *slot[REC_MAX_SLOTS];
    int64_t  ts[REC_MAX_SLOTS];   /* frame UTC time, Windows ticks */
    unsigned long long head, tail;
    int      maxFrames;
    double   maxSecs, t0;
    volatile int dropped;
    volatile int written;
    double   bytesWritten;
    /* SER */
    FILE    *fp;
    int64_t *tsAll;
    int      tsCap;
    char     path[1024];
    int      ioError;
} QCRec;

/* ------------------------------------------------------------------ */
/* state                                                               */
/* ------------------------------------------------------------------ */
typedef struct {
    int      open;
    int      id;
    ASI_CAMERA_INFO info;

    /* current format */
    int      fw, fh, bpp, bin, bits16;
    size_t   frameBytes;

    /* triple buffer: capture writes back, ready = newest complete, front = preview */
    uint8_t *buf[3];
    int      back, ready, front;
    unsigned readySeq, frontSeq;
    int      haveFront;
    pthread_mutex_t mx;

    /* capture thread */
    pthread_t thr;
    volatile int run;
    volatile int expUs;

    /* stats */
    volatile int captured;
    volatile int fpsX10;
    int      tempX10;
    double   tempTime;

    /* display stretch */
    uint8_t  lut8[256];
    uint8_t *lut16;          /* 65536 entries */
    uint8_t  lutR8[256], lutB8[256];
    uint8_t *lutR16, *lutB16;
    int      wbR, wbB;       /* preview white balance, x100 */
    int      sBlack, sWhite, sGamma;
    int      debayer;

    /* values for file headers */
    int      gainVal, offsetVal;
    int      expAuto, gainAuto;   /* camera picks the value itself */
    char     telescope[72], filter[72];
    int      focalMm;

    QCRec    rec;
    int      hist[256];

    char     err[256];
} QCState;

static QCState g = { .mx = PTHREAD_MUTEX_INITIALIZER, .wbR = 100, .wbB = 100,
                     .rec = { .mx = PTHREAD_MUTEX_INITIALIZER, .cv = PTHREAD_COND_INITIALIZER } };

static double now_sec(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static const char *asi_err_text(int e)
{
    static const char *t[] = {
        "success", "invalid index (no camera?)", "invalid id", "invalid control type",
        "camera closed", "camera removed", "invalid path", "invalid file format",
        "invalid size", "invalid image type", "out of boundary", "timeout",
        "invalid sequence (stop capture first)", "buffer too small",
        "video mode active", "exposure in progress", "general error",
        "invalid mode", "GPS not supported", "GPS version", "GPS FPGA",
        "GPS param out of range", "GPS data invalid"
    };
    if (e >= 0 && e < (int)(sizeof t / sizeof t[0])) return t[e];
    return "unknown error";
}

static int fail(int asiErr, const char *where)
{
    snprintf(g.err, sizeof g.err, "%s: %s (ASI %d)", where, asi_err_text(asiErr), asiErr);
    return -(asiErr ? asiErr : 99);
}

static int fail_msg(const char *msg)
{
    snprintf(g.err, sizeof g.err, "%s", msg);
    return -99;
}

static void copy_str(char *dst, int len, const char *src)
{
    if (!dst || len <= 0) return;
    strncpy(dst, src ? src : "", (size_t)len - 1);
    dst[len - 1] = 0;
}

/* ------------------------------------------------------------------ */
/* Step 12: Orion StarShoot G3 (libssg3.so, loaded at run time)        */
/* ------------------------------------------------------------------ */
/* qc_find_camera("G3Mono"/"G3Color") returns G3_IDX_BASE (+1 colour);
   qc_open() with that index opens the first G3 on USB. g.info is filled
   with the G3's numbers so headers, stacking, solving etc. need no change. */
#define G3_IDX_BASE 1000
#define G3_PIXEL_UM 8.6

static struct {
    void *lib;
    int  (*count)(void);
    int  (*open)(int);
    void (*close)(void);
    int  (*width)(void);
    int  (*height)(void);
    int  (*frameBytes)(void);
    int  (*setGain)(int);
    int  (*setOffset)(int);
    int  (*startExp)(int);
    int  (*expDone)(void);
    int  (*download)(void *, int);
    int  (*readTemp)(int *);
    int  (*cooler)(int, int);
    int  (*readPower)(int *);
    int  (*drain)(int);
    int  (*lastError)(char *, int);
    int  active;                /* the open main camera is a G3 */
    int  colour;
    pthread_mutex_t usb;        /* one G3 USB call at a time */
    volatile int gain, offset, coolOn, coolTargetC;
    volatile int dirty;         /* 1 gain, 2 offset, 4 cooler: still to send */
    volatile int tempX10, powerPct;
    double readT;
    int    stale;               /* Stop left an exposure running in the camera */
    double staleEnd;
} g3 = { .usb = PTHREAD_MUTEX_INITIALIZER };

static int g3_load(void)
{
    char own[1024];
    const char *names[3] = { NULL, "libssg3.so", NULL };
    Dl_info di;
    int i;
    if (g3.lib) return 0;
    if (dladdr((void *)g3_load, &di) && di.dli_fname) {     /* the folder libqbcap.so lives in */
        const char *slash = strrchr(di.dli_fname, '/');
        if (slash) { snprintf(own, sizeof own, "%.*s/libssg3.so", (int)(slash - di.dli_fname), di.dli_fname); names[0] = own; }
    }
    for (i = 0; i < 2 && !g3.lib; i++) if (names[i]) g3.lib = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
    if (!g3.lib) return fail_msg("G3 library not found - put libssg3.so in the QBCap folder (build_lib.sh makes it)");
#define G3SYM(f, n) if (!(*(void **)(&g3.f) = dlsym(g3.lib, n))) { snprintf(g.err, sizeof g.err, "libssg3.so is missing %s - rebuild it with build_lib.sh", n); dlclose(g3.lib); g3.lib = NULL; return -1; }
    G3SYM(count, "ssg3_count") G3SYM(open, "ssg3_open") G3SYM(close, "ssg3_close")
    G3SYM(width, "ssg3_width") G3SYM(height, "ssg3_height") G3SYM(frameBytes, "ssg3_frame_bytes")
    G3SYM(setGain, "ssg3_set_gain") G3SYM(setOffset, "ssg3_set_offset")
    G3SYM(startExp, "ssg3_start_exposure") G3SYM(expDone, "ssg3_exposure_done")
    G3SYM(download, "ssg3_download") G3SYM(readTemp, "ssg3_temp_x10")
    G3SYM(cooler, "ssg3_cooler") G3SYM(readPower, "ssg3_cooler_power")
    G3SYM(drain, "ssg3_drain") G3SYM(lastError, "ssg3_last_error")
#undef G3SYM
    return 0;
}

static int g3_fail(const char *where)
{
    char t[200] = "";
    if (g3.lib) g3.lastError(t, sizeof t);
    snprintf(g.err, sizeof g.err, "%s: %s", where, t[0] ? t : "failed");
    return -99;
}

/* number of G3s on USB, or -1 if libssg3.so can't be loaded */
int qc_g3_count(void)
{
    if (g3_load()) return -1;
    if (g3.active) return 1;         /* don't rescan USB under an open camera */
    return g3.count();
}

/* send changed settings (between frames) and read temperature / cooler
   power (at most every 2 s, or now if forceRead) */
static void g3_service(int sendSettings, int forceRead)
{
    int t, p, d;
    if (!g3.active) return;
    pthread_mutex_lock(&g3.usb);
    if (sendSettings) {
        d = __atomic_exchange_n(&g3.dirty, 0, __ATOMIC_SEQ_CST);
        if ((d & 1) && g3.setGain(g3.gain)) g3_fail("G3 gain");
        if ((d & 2) && g3.setOffset(g3.offset)) g3_fail("G3 offset");
        if ((d & 4) && g3.cooler(g3.coolOn, g3.coolTargetC * 10)) g3_fail("G3 cooler");
        if (d & 4) forceRead = 1;    /* show the cooler's answer at once */
    }
    if (forceRead || now_sec() - g3.readT >= 2.0) {
        if (g3.readTemp(&t) == 0) g3.tempX10 = t;
        if (g3.readPower(&p) == 0) g3.powerPct = p;
        g3.readT = now_sec();
    }
    pthread_mutex_unlock(&g3.usb);
}

static int g3_ctrl_range(int ctl, int *mn, int *mxv, int *dflt, int *canAuto)
{
    *canAuto = 0;
    switch (ctl) {
        case ASI_GAIN:        *mn = 0; *mxv = 255; *dflt = 185; return 0;
        case ASI_OFFSET:      *mn = 0; *mxv = 255; *dflt = 127; return 0;
        case ASI_EXPOSURE:    *mn = 1000; *mxv = 600000000; *dflt = 1000000; return 0;
        case ASI_TEMPERATURE: *mn = -500; *mxv = 1000; *dflt = 0; return 0;
        case ASI_TARGET_TEMP: *mn = -40; *mxv = 30; *dflt = 0; return 0;
        case ASI_COOLER_ON:   *mn = 0; *mxv = 1; *dflt = 0; return 0;
        case ASI_COOLER_POWER_PERC: *mn = 0; *mxv = 100; *dflt = 0; return 0;
    }
    return -1;                       /* the G3 has no such control */
}

static int g3_ctrl_set(int ctl, int value)
{
    switch (ctl) {
        case ASI_EXPOSURE:
            g.expUs = value < 1000 ? 1000 : value;   /* G3 counts whole ms */
            g.expAuto = 0;
            return 0;
        case ASI_GAIN:
            if (value < 0) value = 0;
            if (value > 255) value = 255;
            g3.gain = g.gainVal = value; g.gainAuto = 0;
            __atomic_or_fetch(&g3.dirty, 1, __ATOMIC_SEQ_CST);
            break;
        case ASI_OFFSET:
            if (value < 0) value = 0;
            if (value > 255) value = 255;
            g3.offset = g.offsetVal = value;
            __atomic_or_fetch(&g3.dirty, 2, __ATOMIC_SEQ_CST);
            break;
        case ASI_COOLER_ON:
            g3.coolOn = value ? 1 : 0;
            __atomic_or_fetch(&g3.dirty, 4, __ATOMIC_SEQ_CST);
            break;
        case ASI_TARGET_TEMP:
            g3.coolTargetC = value;
            if (g3.coolOn) __atomic_or_fetch(&g3.dirty, 4, __ATOMIC_SEQ_CST);
            break;
        default:
            return 0;                /* USB bandwidth, high speed ...: nothing to do on a G3 */
    }
    if (!g.run) g3_service(1, 0);    /* idle: send now (running: the capture thread sends it) */
    return 0;
}

static int g3_ctrl_get(int ctl, int *value, int *autoOn)
{
    *autoOn = 0;
    if (!g.run) g3_service(0, 0);
    switch (ctl) {
        case ASI_EXPOSURE:    *value = g.expUs; return 0;
        case ASI_GAIN:        *value = g3.gain; return 0;
        case ASI_OFFSET:      *value = g3.offset; return 0;
        case ASI_TEMPERATURE: *value = g3.tempX10; return 0;
        case ASI_TARGET_TEMP: *value = g3.coolTargetC; return 0;
        case ASI_COOLER_ON:   *value = g3.coolOn; return 0;
        case ASI_COOLER_POWER_PERC: *value = g3.powerPct; return 0;
    }
    return fail_msg("the G3 has no such control");
}

int qc_set_format(int bin, int bits16, int roiW, int roiH);
int qc_set_stretch(int black, int white, int gammaX100, int debayer);

static int g3_open(int colour)
{
    int r;
    if (g3_load()) return -1;
    r = g3.count();
    if (r <= 0) return fail_msg("no Orion G3 found on USB (plugged in? 99-orionssg3.rules installed? Ekos closed?)");
    pthread_mutex_lock(&g3.usb);
    r = g3.open(0);
    if (r == 0 && !g3.stale) g3.drain(300);   /* throw away anything left from an earlier program */
    pthread_mutex_unlock(&g3.usb);
    if (r) return g3_fail("G3 open (Ekos/indiserver still running?)");

    memset(&g.info, 0, sizeof g.info);
    snprintf(g.info.Name, sizeof g.info.Name, "%s", colour ? "Orion StarShoot G3 Color" : "Orion StarShoot G3 Mono");
    g.info.CameraID = -1;
    g.info.MaxWidth = g3.width();
    g.info.MaxHeight = g3.height();
    /* the colour G3's sensor is read out raw (no RGB Bayer debayer) for now */
    g.info.IsColorCam = ASI_FALSE;
    g.info.SupportedBins[0] = 1;
    g.info.SupportedVideoFormat[0] = ASI_IMG_RAW16;
    g.info.SupportedVideoFormat[1] = ASI_IMG_END;
    g.info.PixelSize = G3_PIXEL_UM;
    g.info.ST4Port = ASI_FALSE;      /* guiding through the G3 comes later */
    g.info.IsCoolerCam = ASI_TRUE;
    g.info.BitDepth = 16;
    g.id = -1;

    g3.active = 1;
    g3.colour = colour;
    g3.gain = g.gainVal = 185;
    g3.offset = g.offsetVal = 127;
    g3.coolOn = 0; g3.coolTargetC = 0;
    g3.dirty = 3;
    g3.readT = 0;
    g.expAuto = g.gainAuto = 0;
    g.open = 1;
    g.expUs = 1000000;
    g.tempTime = 0;
    if (!g.lut16) qc_set_stretch(0, 255, 100, 0);
    g3_service(1, 1);
    return qc_set_format(1, 1, 0, 0);
}

static void g3_close(void)
{
    pthread_mutex_lock(&g3.usb);
    g3.close();
    pthread_mutex_unlock(&g3.usb);
    g3.active = 0;
}

static void cap_frame_arrived(double *t0, int *n0);

/* G3 capture: no video mode, so expose -> wait -> download, over and over */
static void *g3_cap_thread(void *arg)
{
    double t0 = now_sec(), tEnd;
    int n0 = 0, e, ms;
    (void)arg;
    /* an exposure left running by an earlier Stop: let it finish, discard its data */
    if (g3.stale) {
        snprintf(g.err, sizeof g.err, "G3: waiting for the stopped exposure to finish");
        while (g.run && now_sec() < g3.staleEnd) usleep(50000);
        if (!g.run) return NULL;
        pthread_mutex_lock(&g3.usb);
        g3.drain(3000);
        pthread_mutex_unlock(&g3.usb);
        g3.stale = 0;
        g.err[0] = 0;
    }
    while (g.run) {
        g3_service(1, 0);
        ms = g.expUs / 1000;
        if (ms < 1) ms = 1;
        pthread_mutex_lock(&g3.usb);
        e = g3.startExp(ms);
        pthread_mutex_unlock(&g3.usb);
        if (e) { g3_fail("G3 start exposure"); usleep(500000); continue; }
        tEnd = now_sec() + ms / 1000.0;
        /* wait in short steps so Stop answers at once; temperature is read meanwhile */
        while (g.run && !g3.expDone()) {
            usleep(20000);
            g3_service(0, 0);
        }
        if (!g.run) {                 /* the camera has no abort: remember it is still busy */
            g3.stale = 1;
            g3.staleEnd = tEnd + 0.5;
            break;
        }
        pthread_mutex_lock(&g3.usb);
        e = g3.download(g.buf[g.back], (int)g.frameBytes);
        pthread_mutex_unlock(&g3.usb);
        if (e) { g3_fail("G3 download"); usleep(200000); continue; }
        cap_frame_arrived(&t0, &n0);
        if (now_sec() - t0 > 3.0 + g.expUs / 1e6) g.fpsX10 = 0;
    }
    return NULL;
}

/* ------------------------------------------------------------------ */
/* Step 14: QHY main camera - state here, code after the PoleMaster    */
/* (it shares the PoleMaster's libqhyccd.so function table)            */
/* ------------------------------------------------------------------ */
#define QH_IDX_BASE 3000

static struct {
    int      active;            /* the open main camera is a QHY */
    void    *h;                 /* qhyccd handle */
    char     id[64], name[64];
    int      w, h_, bits;       /* full frame, transfer bits (8/16) */
    double   pixUm;
    uint8_t *raw;               /* SDK frame buffer (GetQHYCCDMemLength) */
    size_t   memLen;
    volatile int gain, offset;
    volatile int dirty;         /* 1 exposure, 2 gain, 4 offset: still to send */
    int      gainMin, gainMax, offMin, offMax;
    int      expMinUs, expMaxUs;
} qh;

int  qc_qhy_count(void);
int  qc_qhy_blank(void);
static int qh_boot_and_wait(void);
static int  qh_open(void);
static void qh_close(void);
static int  qh_set_bits(int bits16);
static void qh_cancel(void);
static int  qh_ctrl_range(int ctl, int *mn, int *mxv, int *dflt, int *canAuto);
static int  qh_ctrl_set(int ctl, int value);
static int  qh_ctrl_get(int ctl, int *value, int *autoOn);
static void *qh_cap_thread(void *arg);

/* ------------------------------------------------------------------ */
/* Step 13: standard Linux USB camera (V4L2)                          */
/* ------------------------------------------------------------------ */
/* qc_find_camera("USBCam") -> UV_IDX_BASE. The first /dev/videoN that can
   send raw 8-bit Bayer (or mono GREY) frames is used, at its largest size.
   g.info is filled in so preview/debayer/SER/FITS/stacking need no change. */
#define UV_IDX_BASE 2000
#define UV_NBUF 4

static struct {
    int      active, fd, nbuf;
    char     dev[64], name[64];
    uint32_t fourcc;
    int      w, h;
    void    *mem[UV_NBUF];
    size_t   len[UV_NBUF];
    unsigned vid, pid;
} uv = { .fd = -1 };

static int uv_ioctl(int fd, unsigned long req, void *arg)
{
    int r;
    do r = ioctl(fd, req, arg); while (r == -1 && errno == EINTR);
    return r;
}

static int uv_fourcc_ok(uint32_t f)
{
    return f == V4L2_PIX_FMT_SBGGR8 || f == V4L2_PIX_FMT_SGBRG8 ||
           f == V4L2_PIX_FMT_SGRBG8 || f == V4L2_PIX_FMT_SRGGB8 || f == V4L2_PIX_FMT_GREY;
}

static unsigned uv_sysfs_hex(const char *node, const char *file)
{
    char path[256], t[32] = "";
    FILE *fp;
    snprintf(path, sizeof path, "/sys/class/video4linux/%s/device/../%s", node, file);
    fp = fopen(path, "r");
    if (!fp) return 0;
    if (!fgets(t, sizeof t, fp)) t[0] = 0;
    fclose(fp);
    return (unsigned)strtoul(t, NULL, 16);
}

/* find the camera: fills uv.dev, uv.name, uv.fourcc, uv.w, uv.h, uv.vid, uv.pid */
static int uv_probe(void)
{
    int i;
    for (i = 0; i < 64; i++) {
        char path[64], node[32];
        struct v4l2_capability cap;
        struct v4l2_fmtdesc fd;
        uint32_t caps, bestF = 0;
        int fh, bestW = 0, bestH = 0;
        snprintf(node, sizeof node, "video%d", i);
        snprintf(path, sizeof path, "/dev/%s", node);
        fh = open(path, O_RDWR | O_NONBLOCK);
        if (fh < 0) continue;
        memset(&cap, 0, sizeof cap);
        if (uv_ioctl(fh, VIDIOC_QUERYCAP, &cap)) { close(fh); continue; }
        caps = (cap.capabilities & V4L2_CAP_DEVICE_CAPS) ? cap.device_caps : cap.capabilities;
        if (!(caps & V4L2_CAP_VIDEO_CAPTURE) || !(caps & V4L2_CAP_STREAMING)) { close(fh); continue; }
        memset(&fd, 0, sizeof fd);
        fd.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        for (fd.index = 0; uv_ioctl(fh, VIDIOC_ENUM_FMT, &fd) == 0; fd.index++) {
            struct v4l2_frmsizeenum fs;
            if (!uv_fourcc_ok(fd.pixelformat)) continue;
            memset(&fs, 0, sizeof fs);
            fs.pixel_format = fd.pixelformat;
            for (fs.index = 0; uv_ioctl(fh, VIDIOC_ENUM_FRAMESIZES, &fs) == 0; fs.index++) {
                int w, h;
                if (fs.type == V4L2_FRMSIZE_TYPE_DISCRETE) { w = fs.discrete.width; h = fs.discrete.height; }
                else { w = fs.stepwise.max_width; h = fs.stepwise.max_height; }
                if (w * h > bestW * bestH) { bestW = w; bestH = h; bestF = fd.pixelformat; }
                if (fs.type != V4L2_FRMSIZE_TYPE_DISCRETE) break;
            }
        }
        close(fh);
        if (bestF) {
            unsigned prod = 0;
            char t[64] = "", pf[256];
            FILE *fp;
            snprintf(uv.dev, sizeof uv.dev, "%s", path);
            uv.fourcc = bestF; uv.w = bestW; uv.h = bestH;
            uv.vid = uv_sysfs_hex(node, "idVendor");
            uv.pid = uv_sysfs_hex(node, "idProduct");
            snprintf(pf, sizeof pf, "/sys/class/video4linux/%s/device/../product", node);
            fp = fopen(pf, "r");
            if (fp) { if (fgets(t, sizeof t, fp)) { char *e = t + strlen(t); while (e > t && (e[-1] == '\n' || e[-1] == ' ')) *--e = 0; } fclose(fp); }
            (void)prod;
            snprintf(uv.name, sizeof uv.name, "USB camera: %s", t[0] ? t : (const char *)cap.card);
            return 0;
        }
    }
    return -1;
}

/* 1 if a usable USB camera is there, 0 if not */
int qc_usbcam_count(void)
{
    if (uv.active) return 1;
    return uv_probe() == 0 ? 1 : 0;
}

static void uv_unmap(void)
{
    int i;
    for (i = 0; i < uv.nbuf; i++) if (uv.mem[i] && uv.mem[i] != MAP_FAILED) munmap(uv.mem[i], uv.len[i]);
    memset(uv.mem, 0, sizeof uv.mem);
    uv.nbuf = 0;
}

static void uv_close(void)
{
    if (uv.fd >= 0) {
        int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        uv_ioctl(uv.fd, VIDIOC_STREAMOFF, &type);
        uv_unmap();
        close(uv.fd);
    }
    uv.fd = -1;
    uv.active = 0;
}

static int uv_fail(const char *what)
{
    snprintf(g.err, sizeof g.err, "%s (%s): %s", what, uv.dev, strerror(errno));
    uv_close();
    return -99;
}

int qc_set_format(int bin, int bits16, int roiW, int roiH);

static int uv_open(void)
{
    struct v4l2_format f;
    struct v4l2_requestbuffers rb;
    int i;
    if (uv_probe()) return fail_msg("no USB camera with raw 8-bit output found (plugged in? ls /dev/video*)");
    uv.fd = open(uv.dev, O_RDWR | O_NONBLOCK);
    if (uv.fd < 0) { snprintf(g.err, sizeof g.err, "open %s: %s (in the video group?)", uv.dev, strerror(errno)); uv.fd = -1; return -99; }

    memset(&f, 0, sizeof f);
    f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    f.fmt.pix.width = uv.w;
    f.fmt.pix.height = uv.h;
    f.fmt.pix.pixelformat = uv.fourcc;
    f.fmt.pix.field = V4L2_FIELD_NONE;
    if (uv_ioctl(uv.fd, VIDIOC_S_FMT, &f)) return uv_fail("set format");
    uv.w = f.fmt.pix.width; uv.h = f.fmt.pix.height; uv.fourcc = f.fmt.pix.pixelformat;
    if (!uv_fourcc_ok(uv.fourcc)) { errno = EINVAL; return uv_fail("camera refused raw 8-bit format"); }

    memset(&rb, 0, sizeof rb);
    rb.count = UV_NBUF; rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; rb.memory = V4L2_MEMORY_MMAP;
    if (uv_ioctl(uv.fd, VIDIOC_REQBUFS, &rb) || rb.count < 2) return uv_fail("request buffers");
    uv.nbuf = rb.count > UV_NBUF ? UV_NBUF : (int)rb.count;
    for (i = 0; i < uv.nbuf; i++) {
        struct v4l2_buffer b;
        memset(&b, 0, sizeof b);
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; b.memory = V4L2_MEMORY_MMAP; b.index = i;
        if (uv_ioctl(uv.fd, VIDIOC_QUERYBUF, &b)) return uv_fail("query buffer");
        uv.len[i] = b.length;
        uv.mem[i] = mmap(NULL, b.length, PROT_READ | PROT_WRITE, MAP_SHARED, uv.fd, b.m.offset);
        if (uv.mem[i] == MAP_FAILED) { uv.mem[i] = NULL; return uv_fail("map buffer"); }
    }

    memset(&g.info, 0, sizeof g.info);
    snprintf(g.info.Name, sizeof g.info.Name, "%s", uv.name);
    g.info.CameraID = -1;
    g.info.MaxWidth = uv.w;
    g.info.MaxHeight = uv.h;
    g.info.IsColorCam = uv.fourcc == V4L2_PIX_FMT_GREY ? ASI_FALSE : ASI_TRUE;
    switch (uv.fourcc) {
        case V4L2_PIX_FMT_SBGGR8: g.info.BayerPattern = ASI_BAYER_BG; break;
        case V4L2_PIX_FMT_SGBRG8: g.info.BayerPattern = ASI_BAYER_GB; break;
        case V4L2_PIX_FMT_SGRBG8: g.info.BayerPattern = ASI_BAYER_GR; break;
        default:                  g.info.BayerPattern = ASI_BAYER_RG; break;
    }
    g.info.SupportedBins[0] = 1;
    g.info.SupportedVideoFormat[0] = ASI_IMG_RAW8;
    g.info.SupportedVideoFormat[1] = ASI_IMG_END;
    /* Microdia 0c45:6242 = MI1310 (MT9M111), 3.6 um; other cameras: a typical value */
    g.info.PixelSize = (uv.vid == 0x0c45 && uv.pid == 0x6242) ? 3.6 : 3.0;
    g.info.BitDepth = 8;
    g.id = -1;

    uv.active = 1;
    g.open = 1;
    g.expUs = 10000;
    g.expAuto = g.gainAuto = 0;
    g.gainVal = g.offsetVal = 0;
    g.tempX10 = 0;
    if (!g.lut16) qc_set_stretch(0, 255, 100, 0);
    return qc_set_format(1, 0, 0, 0);
}

static int uv_streamon(void)
{
    int i, type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    for (i = 0; i < uv.nbuf; i++) {
        struct v4l2_buffer b;
        memset(&b, 0, sizeof b);
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; b.memory = V4L2_MEMORY_MMAP; b.index = i;
        if (uv_ioctl(uv.fd, VIDIOC_QBUF, &b)) { snprintf(g.err, sizeof g.err, "queue buffer: %s", strerror(errno)); return -99; }
    }
    if (uv_ioctl(uv.fd, VIDIOC_STREAMON, &type)) { snprintf(g.err, sizeof g.err, "start stream: %s", strerror(errno)); return -99; }
    return 0;
}

static void uv_streamoff(void)
{
    int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (uv.fd >= 0) uv_ioctl(uv.fd, VIDIOC_STREAMOFF, &type);   /* also takes back every buffer */
}

static void *uv_cap_thread(void *arg)
{
    double t0 = now_sec();
    int n0 = 0;
    (void)arg;
    while (g.run) {
        struct pollfd pf = { uv.fd, POLLIN, 0 };
        struct v4l2_buffer b;
        int r = poll(&pf, 1, 500);
        if (r <= 0) {
            if (now_sec() - t0 > 3.0) g.fpsX10 = 0;
            continue;
        }
        memset(&b, 0, sizeof b);
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; b.memory = V4L2_MEMORY_MMAP;
        if (uv_ioctl(uv.fd, VIDIOC_DQBUF, &b)) {
            if (errno != EAGAIN) { snprintf(g.err, sizeof g.err, "USB camera read: %s", strerror(errno)); usleep(20000); }
            continue;
        }
        if (b.index < (unsigned)uv.nbuf && !(b.flags & V4L2_BUF_FLAG_ERROR) && b.bytesused > 0) {
            size_t n = b.bytesused;
            if (n > g.frameBytes) n = g.frameBytes;
            memcpy(g.buf[g.back], uv.mem[b.index], n);
            /* some drivers send a row short (SN9C20x: 1280x1023) - blank the rest */
            if (n < g.frameBytes) memset(g.buf[g.back] + n, 0, g.frameBytes - n);
            uv_ioctl(uv.fd, VIDIOC_QBUF, &b);
            cap_frame_arrived(&t0, &n0);
        } else {
            uv_ioctl(uv.fd, VIDIOC_QBUF, &b);
        }
    }
    return NULL;
}

/* V4L2 control helpers: 0 if the control exists (and is usable) */
static int uv_qctrl(uint32_t id, int *mn, int *mxv, int *dflt)
{
    struct v4l2_queryctrl q;
    memset(&q, 0, sizeof q);
    q.id = id;
    if (uv_ioctl(uv.fd, VIDIOC_QUERYCTRL, &q) || (q.flags & V4L2_CTRL_FLAG_DISABLED)) return -1;
    if (mn) *mn = q.minimum;
    if (mxv) *mxv = q.maximum;
    if (dflt) *dflt = q.default_value;
    return 0;
}
static int uv_sctrl(uint32_t id, int v) { struct v4l2_control c = { id, v }; return uv_ioctl(uv.fd, VIDIOC_S_CTRL, &c); }
static int uv_gctrl(uint32_t id, int *v) { struct v4l2_control c = { id, 0 }; int r = uv_ioctl(uv.fd, VIDIOC_G_CTRL, &c); if (!r) *v = c.value; return r; }

/* exposure: V4L2 absolute exposure is in 100 us steps; QBCap uses us */
static int uv_ctrl_range(int ctl, int *mn, int *mxv, int *dflt, int *canAuto)
{
    *canAuto = 0;
    if (ctl == ASI_EXPOSURE) {
        if (uv_qctrl(V4L2_CID_EXPOSURE_ABSOLUTE, mn, mxv, dflt)) return -1;
        *mn *= 100; *mxv *= 100; *dflt *= 100;
        *canAuto = uv_qctrl(V4L2_CID_EXPOSURE_AUTO, NULL, NULL, NULL) == 0;
        return 0;
    }
    if (ctl == ASI_GAIN) {
        if (uv_qctrl(V4L2_CID_GAIN, mn, mxv, dflt)) return -1;
        *canAuto = uv_qctrl(V4L2_CID_AUTOGAIN, NULL, NULL, NULL) == 0;
        return 0;
    }
    return -1;
}

static int uv_ctrl_set(int ctl, int value, int autoOn)
{
    if (ctl == ASI_EXPOSURE) {
        if (uv_qctrl(V4L2_CID_EXPOSURE_ABSOLUTE, NULL, NULL, NULL))
            return fail_msg("this USB camera sets its own exposure (no exposure control)");
        if (uv_qctrl(V4L2_CID_EXPOSURE_AUTO, NULL, NULL, NULL) == 0)
            uv_sctrl(V4L2_CID_EXPOSURE_AUTO, autoOn ? V4L2_EXPOSURE_APERTURE_PRIORITY : V4L2_EXPOSURE_MANUAL);
        if (!autoOn && uv_sctrl(V4L2_CID_EXPOSURE_ABSOLUTE, value / 100 > 0 ? value / 100 : 1))
            return fail_msg("USB camera refused the exposure");
        g.expUs = value; g.expAuto = autoOn ? 1 : 0;
        return 0;
    }
    if (ctl == ASI_GAIN) {
        if (uv_qctrl(V4L2_CID_GAIN, NULL, NULL, NULL)) return fail_msg("this USB camera has no gain control");
        if (uv_qctrl(V4L2_CID_AUTOGAIN, NULL, NULL, NULL) == 0) uv_sctrl(V4L2_CID_AUTOGAIN, autoOn ? 1 : 0);
        if (!autoOn && uv_sctrl(V4L2_CID_GAIN, value)) return fail_msg("USB camera refused the gain");
        g.gainVal = value; g.gainAuto = autoOn ? 1 : 0;
        return 0;
    }
    if (ctl == ASI_OFFSET) return fail_msg("this USB camera has no offset control");
    if (ctl == ASI_COOLER_ON || ctl == ASI_TARGET_TEMP) return fail_msg("this USB camera has no cooler");
    return 0;                        /* USB bandwidth, high speed ...: nothing to do */
}

static int uv_ctrl_get(int ctl, int *value, int *autoOn)
{
    int v = 0;
    *autoOn = 0;
    if (ctl == ASI_EXPOSURE && uv_gctrl(V4L2_CID_EXPOSURE_ABSOLUTE, &v) == 0) { *value = v * 100; *autoOn = g.expAuto; return 0; }
    if (ctl == ASI_GAIN && uv_gctrl(V4L2_CID_GAIN, &v) == 0) { *value = v; *autoOn = g.gainAuto; return 0; }
    return fail_msg("this USB camera has no such control");
}

/* ------------------------------------------------------------------ */
/* info                                                                */
/* ------------------------------------------------------------------ */
int qc_version(void) { return QC_VERSION; }

int qc_sdk_version(char *buf, int len)
{
    copy_str(buf, len, ASIGetSDKVersion());
    return 0;
}

int qc_last_error(char *buf, int len)
{
    copy_str(buf, len, g.err);
    return 0;
}

int qc_camera_count(void) { return ASIGetNumOfConnectedCameras(); }

int qc_camera_name(int idx, char *buf, int len)
{
    ASI_CAMERA_INFO ci;
    int e;
    if (idx >= QH_IDX_BASE) {
        if (qh.active) { copy_str(buf, len, qh.name); return 0; }
        if (qc_qhy_count() <= 0) { copy_str(buf, len, ""); return fail_msg("no QHY camera found"); }
        copy_str(buf, len, qh.name[0] ? qh.name : "QHY camera");
        return 0;
    }
    if (idx >= UV_IDX_BASE) {
        if (!uv.active && uv_probe()) { copy_str(buf, len, ""); return fail_msg("no USB camera found"); }
        copy_str(buf, len, uv.name);
        return 0;
    }
    if (idx >= G3_IDX_BASE) {
        copy_str(buf, len, idx > G3_IDX_BASE ? "Orion StarShoot G3 Color" : "Orion StarShoot G3 Mono");
        return 0;
    }
    e = ASIGetCameraProperty(&ci, idx);
    if (e) { copy_str(buf, len, ""); return fail(e, "qc_camera_name"); }
    copy_str(buf, len, ci.Name);
    return 0;
}

/* returns index of first connected camera whose name contains namePart, or -1 */
int qc_find_camera(const char *namePart)
{
    int n, i;
    if (namePart && strncmp(namePart, "QHYCam", 6) == 0) {
        int k = qc_qhy_count();
        if (k < 0) return -1;
        if (k == 0) k = qh_boot_and_wait();     /* a blank All-in-One: load its firmware first */
        if (k < 0) return -1;
        if (k == 0) { snprintf(g.err, sizeof g.err, "no QHY camera found on USB (plugged in? check the cable / port)"); return -1; }
        return QH_IDX_BASE;
    }
    if (namePart && strncmp(namePart, "USBCam", 6) == 0) {
        if (qc_usbcam_count() <= 0) { snprintf(g.err, sizeof g.err, "no USB camera with raw 8-bit output found (plugged in? ls /dev/video*)"); return -1; }
        return UV_IDX_BASE;
    }
    if (namePart && strncmp(namePart, "G3", 2) == 0) {     /* "G3Mono" / "G3Color" */
        int k = qc_g3_count();
        if (k < 0) return -1;
        if (k == 0) { snprintf(g.err, sizeof g.err, "no Orion G3 found on USB (plugged in? 99-orionssg3.rules installed?)"); return -1; }
        return G3_IDX_BASE + (strstr(namePart, "Color") ? 1 : 0);
    }
    n = ASIGetNumOfConnectedCameras();
    for (i = 0; i < n; i++) {
        ASI_CAMERA_INFO ci;
        if (ASIGetCameraProperty(&ci, i) == ASI_SUCCESS && strstr(ci.Name, namePart))
            return i;
    }
    snprintf(g.err, sizeof g.err, "%s not found (%d ZWO camera(s) on USB)", namePart, n);
    return -1;
}

/* ------------------------------------------------------------------ */
/* buffers / stretch                                                   */
/* ------------------------------------------------------------------ */
static void free_buffers(void)
{
    int i;
    for (i = 0; i < 3; i++) { free(g.buf[i]); g.buf[i] = NULL; }
}

static int alloc_buffers(void)
{
    int i;
    free_buffers();
    for (i = 0; i < 3; i++) {
        g.buf[i] = (uint8_t *)calloc(1, g.frameBytes);
        if (!g.buf[i]) { free_buffers(); return fail_msg("out of memory for frame buffers"); }
    }
    g.back = 0; g.ready = 1; g.front = 2;
    g.readySeq = g.frontSeq = 0;
    g.haveFront = 0;
    return 0;
}

static void build_wb_luts(void)
{
    int i;
    for (i = 0; i < 65536; i++) {
        long r = (long)i * g.wbR / 100, b = (long)i * g.wbB / 100;
        g.lutR16[i] = g.lut16[r > 65535 ? 65535 : r];
        g.lutB16[i] = g.lut16[b > 65535 ? 65535 : b];
    }
    for (i = 0; i < 256; i++) { g.lutR8[i] = g.lutR16[i * 257]; g.lutB8[i] = g.lutB16[i * 257]; }
}

int qc_set_stretch(int black, int white, int gammaX100, int debayer)
{
    int i;
    double b, w, inv;
    if (!g.lut16) g.lut16 = (uint8_t *)malloc(65536);
    if (!g.lutR16) g.lutR16 = (uint8_t *)malloc(65536);
    if (!g.lutB16) g.lutB16 = (uint8_t *)malloc(65536);
    if (!g.lut16 || !g.lutR16 || !g.lutB16) return fail_msg("out of memory for LUT");
    if (black < 0) black = 0;
    if (white > 255) white = 255;
    if (white <= black) white = black + 1;
    if (gammaX100 < 10) gammaX100 = 10;
    g.sBlack = black; g.sWhite = white; g.sGamma = gammaX100;
    b = black / 255.0; w = white / 255.0;
    inv = 100.0 / gammaX100;           /* gamma > 1 brightens midtones */
    for (i = 0; i < 65536; i++) {
        double t = (i / 65535.0 - b) / (w - b);
        if (t < 0) t = 0;
        if (t > 1) t = 1;
        g.lut16[i] = (uint8_t)(pow(t, inv) * 255.0 + 0.5);
    }
    for (i = 0; i < 256; i++) g.lut8[i] = g.lut16[i * 257];
    build_wb_luts();
    g.debayer = debayer ? 1 : 0;
    return 0;
}

/* preview-only white balance for colour cameras (raw files are never changed) */
int qc_set_wb(int redX100, int blueX100)
{
    if (redX100 < 10) redX100 = 10;
    if (blueX100 < 10) blueX100 = 10;
    g.wbR = redX100; g.wbB = blueX100;
    if (g.lut16 && g.lutR16 && g.lutB16) build_wb_luts();
    return 0;
}

int qc_set_meta(const char *telescope, int focalMm, const char *filter)
{
    snprintf(g.telescope, sizeof g.telescope, "%s", telescope ? telescope : "");
    snprintf(g.filter, sizeof g.filter, "%s", filter ? filter : "");
    g.focalMm = focalMm;
    return 0;
}

/* ------------------------------------------------------------------ */
/* open / close / format                                               */
/* ------------------------------------------------------------------ */
void qc_stop(void);
void qc_record_stop(void);
void qc_master_cancel(void);
static void refresh_auto_values(void);
static void lucky_reset(void);
void qc_stack_stop(void);
int  qc_start_video(void);
int  qc_set_format(int bin, int bits16, int roiW, int roiH);

int qc_open(int idx)
{
    int e;
    if (g.open) return fail_msg("a camera is already open");
    if (idx >= QH_IDX_BASE) return qh_open();
    if (idx >= UV_IDX_BASE) return uv_open();
    if (idx >= G3_IDX_BASE) return g3_open(idx > G3_IDX_BASE);
    e = ASIGetCameraProperty(&g.info, idx);
    if (e) return fail(e, "ASIGetCameraProperty");
    g.id = g.info.CameraID;
    e = ASIOpenCamera(g.id);
    if (e) return fail(e, "ASIOpenCamera (udev rule installed?)");
    e = ASIInitCamera(g.id);
    if (e) { ASICloseCamera(g.id); return fail(e, "ASIInitCamera"); }
    g.open = 1;
    g.expUs = 10000;
    g.tempTime = 0;
    if (!g.lut16) qc_set_stretch(0, 255, 100, 0);
    /* sensible defaults; QB64 sends its own values right after */
    ASISetControlValue(g.id, ASI_BANDWIDTHOVERLOAD, 80, ASI_FALSE);
    ASISetControlValue(g.id, ASI_EXPOSURE, g.expUs, ASI_FALSE);
    ASISetControlValue(g.id, ASI_HIGH_SPEED_MODE, 1, ASI_FALSE);
    return qc_set_format(1, 0, 0, 0);
}

void qc_close(void)
{
    if (!g.open) return;
    qc_record_stop();
    qc_master_cancel();
    qc_stack_stop();
    qc_stop();
    if (g3.active) g3_close();
    else if (uv.active) uv_close();
    else if (qh.active) qh_close();
    else ASICloseCamera(g.id);
    free_buffers();
    g.open = 0;
}

int qc_is_open(void) { return g.open; }

int qc_sensor_info(int *w, int *h, int *isColor, int *bayer, int *bitDepth,
                   int *isCooled, int *pixX100, int *usb3)
{
    if (!g.open) return fail_msg("no camera open");
    *w = (int)g.info.MaxWidth;
    *h = (int)g.info.MaxHeight;
    *isColor = g.info.IsColorCam ? 1 : 0;
    *bayer = (int)g.info.BayerPattern;
    *bitDepth = g.info.BitDepth;
    *isCooled = g.info.IsCoolerCam ? 1 : 0;
    *pixX100 = (int)(g.info.PixelSize * 100.0 + 0.5);
    *usb3 = (g.info.IsUSB3Host && g.info.IsUSB3Camera) ? 1 : 0;
    return 0;
}

/* bin 1..4, bits16 0/1, roiW/roiH in binned pixels (0 = full), centred on sensor */
int qc_set_format(int bin, int bits16, int roiW, int roiH)
{
    int e, wasRunning, fullW, fullH, w, h, sx, sy;
    if (!g.open) return fail_msg("no camera open");
    if (bin < 1) bin = 1;
    qc_record_stop();              /* frame size is about to change */
    qc_stack_stop();
    wasRunning = g.run;
    if (wasRunning) qc_stop();

    if (uv.active) {               /* USB camera: 8-bit, full frame, bin 1 */
        g.fw = uv.w; g.fh = uv.h;
        g.bin = 1; g.bits16 = 0; g.bpp = 1;
        g.frameBytes = (size_t)g.fw * g.fh;
        e = alloc_buffers();
        if (e) return e;
        if (wasRunning) return qc_start_video();
        return 0;
    }
    if (qh.active) {               /* QHY: 8- or 16-bit, full frame, bin 1 */
        e = qh_set_bits(bits16);
        if (e) return e;
        g.fw = qh.w; g.fh = qh.h_;
        g.bin = 1; g.bits16 = qh.bits > 8 ? 1 : 0; g.bpp = g.bits16 ? 2 : 1;
        g.frameBytes = (size_t)g.fw * g.fh * g.bpp;
        e = alloc_buffers();
        if (e) return e;
        if (wasRunning) return qc_start_video();
        return 0;
    }
    if (g3.active) {               /* G3: always 16-bit, full frame, bin 1 */
        g.fw = (int)g.info.MaxWidth; g.fh = (int)g.info.MaxHeight;
        g.bin = 1; g.bits16 = 1; g.bpp = 2;
        g.frameBytes = (size_t)g.fw * g.fh * 2;
        e = alloc_buffers();
        if (e) return e;
        if (wasRunning) return qc_start_video();
        return 0;
    }

    fullW = (int)g.info.MaxWidth / bin;
    fullH = (int)g.info.MaxHeight / bin;
    w = (roiW > 0 && roiW < fullW) ? roiW : fullW;
    h = (roiH > 0 && roiH < fullH) ? roiH : fullH;
    w &= ~7;                       /* SDK: width multiple of 8 */
    h &= ~1;                       /* SDK: height multiple of 2 */
    if (!g.info.IsUSB3Camera)      /* USB2 cameras also want w*h % 1024 == 0 */
        while (w > 8 && ((w * h) % 1024)) w -= 8;

    e = ASISetROIFormat(g.id, w, h, bin, bits16 ? ASI_IMG_RAW16 : ASI_IMG_RAW8);
    if (e) return fail(e, "ASISetROIFormat");
    sx = ((fullW - w) / 2) & ~1;   /* even start keeps the Bayer phase */
    sy = ((fullH - h) / 2) & ~1;
    ASISetStartPos(g.id, sx, sy);

    g.fw = w; g.fh = h; g.bin = bin; g.bits16 = bits16 ? 1 : 0;
    g.bpp = g.bits16 ? 2 : 1;
    g.frameBytes = (size_t)w * h * g.bpp;
    e = alloc_buffers();
    if (e) return e;
    if (wasRunning) return qc_start_video();
    return 0;
}

int qc_frame_size(int *w, int *h, int *bpp)
{
    if (!g.open) return fail_msg("no camera open");
    *w = g.fw; *h = g.fh; *bpp = g.bpp;
    return 0;
}

/* ------------------------------------------------------------------ */
/* controls                                                            */
/* ------------------------------------------------------------------ */
int qc_ctrl_range(int ctl, int *mn, int *mxv, int *dflt, int *canAuto)
{
    int n = 0, i;
    if (!g.open) return fail_msg("no camera open");
    if (g3.active) return g3_ctrl_range(ctl, mn, mxv, dflt, canAuto);
    if (qh.active) return qh_ctrl_range(ctl, mn, mxv, dflt, canAuto);
    if (uv.active) return uv_ctrl_range(ctl, mn, mxv, dflt, canAuto);
    ASIGetNumOfControls(g.id, &n);
    for (i = 0; i < n; i++) {
        ASI_CONTROL_CAPS c;
        if (ASIGetControlCaps(g.id, i, &c) == ASI_SUCCESS && (int)c.ControlType == ctl) {
            *mn = (int)c.MinValue; *mxv = (int)c.MaxValue;
            *dflt = (int)c.DefaultValue; *canAuto = c.IsAutoSupported ? 1 : 0;
            return 0;
        }
    }
    return -1;                      /* this camera has no such control */
}

int qc_ctrl_set(int ctl, int value, int autoOn)
{
    int e;
    if (!g.open) return fail_msg("no camera open");
    if (g3.active) return g3_ctrl_set(ctl, value);
    if (qh.active) return qh_ctrl_set(ctl, value);
    if (uv.active) return uv_ctrl_set(ctl, value, autoOn);
    e = ASISetControlValue(g.id, (ASI_CONTROL_TYPE)ctl, (long)value, autoOn ? ASI_TRUE : ASI_FALSE);
    if (e) return fail(e, "ASISetControlValue");
    if (ctl == ASI_EXPOSURE) { g.expUs = value; g.expAuto = autoOn ? 1 : 0; }
    if (ctl == ASI_GAIN) { g.gainVal = value; g.gainAuto = autoOn ? 1 : 0; }
    if (ctl == ASI_OFFSET) g.offsetVal = value;
    return 0;
}

int qc_ctrl_get(int ctl, int *value, int *autoOn)
{
    long v = 0;
    ASI_BOOL a = ASI_FALSE;
    int e;
    if (!g.open) return fail_msg("no camera open");
    if (g3.active) return g3_ctrl_get(ctl, value, autoOn);
    if (qh.active) return qh_ctrl_get(ctl, value, autoOn);
    if (uv.active) return uv_ctrl_get(ctl, value, autoOn);
    e = ASIGetControlValue(g.id, (ASI_CONTROL_TYPE)ctl, &v, &a);
    if (e) return fail(e, "ASIGetControlValue");
    *value = (int)v;
    *autoOn = a ? 1 : 0;
    return 0;
}

/* ------------------------------------------------------------------ */
/* time + file helpers                                                 */
/* ------------------------------------------------------------------ */
#define TICKS_UNIX_EPOCH 621355968000000000LL   /* 0001-01-01 -> 1970-01-01, 100 ns */

static int64_t utc_ticks(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return TICKS_UNIX_EPOCH + (int64_t)ts.tv_sec * 10000000LL + ts.tv_nsec / 100;
}

static void ticks_to_iso(int64_t t, char *out, size_t n)
{
    int64_t u = t - TICKS_UNIX_EPOCH;
    time_t sec = (time_t)(u / 10000000LL);
    int us = (int)((u % 10000000LL) / 10);
    struct tm tmv;
    gmtime_r(&sec, &tmv);
    snprintf(out, n, "%04d-%02d-%02dT%02d:%02d:%02d.%06d", /* fits in 27 chars */
             tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
             tmv.tm_hour, tmv.tm_min, tmv.tm_sec, us);
}

/* create every directory in the path's parent chain */
static void mkdir_parents(const char *path)
{
    char tmp[1024];
    char *p;
    snprintf(tmp, sizeof tmp, "%s", path);
    for (p = tmp + 1; *p; p++) {
        if (*p == '/') { *p = 0; mkdir(tmp, 0755); *p = '/'; }
    }
}

static void put_le32(uint8_t *p, int32_t v) { int i; for (i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static void put_le64(uint8_t *p, int64_t v) { int i; for (i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i)); }

/* ------------------------------------------------------------------ */
/* FITS writer (one frame)                                             */
/* ------------------------------------------------------------------ */
static void card_raw(char *hdr, int *n, const char *text)
{
    char c[81];
    snprintf(c, sizeof c, "%-80s", text);
    memcpy(hdr + *n * 80, c, 80);
    (*n)++;
}

static void card_int(char *hdr, int *n, const char *key, long v, const char *cmt)
{
    char t[100];
    snprintf(t, sizeof t, "%-8s= %20ld / %s", key, v, cmt);
    card_raw(hdr, n, t);
}

static void card_dbl(char *hdr, int *n, const char *key, double v, const char *cmt)
{
    char t[100];
    snprintf(t, sizeof t, "%-8s= %20.6f / %s", key, v, cmt);
    card_raw(hdr, n, t);
}

static void card_str(char *hdr, int *n, const char *key, const char *v, const char *cmt)
{
    char t[120], q[72];
    snprintf(q, sizeof q, "'%-8.66s'", v);
    snprintf(t, sizeof t, "%-8s= %-20s / %s", key, q, cmt);
    card_raw(hdr, n, t);
}

typedef struct {
    int w, h, bits16, expUs, gain, offset, tempX10, bin, ncombine;
    const char *imagetyp;
} FitsMeta;

static FitsMeta live_meta(void)
{
    FitsMeta m;
    m.w = g.fw; m.h = g.fh; m.bits16 = g.bits16; m.expUs = g.expUs; m.gain = g.gainVal;
    m.offset = g.offsetVal; m.tempX10 = g.tempX10; m.bin = g.bin; m.ncombine = 0;
    m.imagetyp = "Light Frame";
    return m;
}

static int write_fits_m(const char *path, const uint8_t *data, int64_t ticks, const FitsMeta *m)
{
    char hdr[2880 * 2];
    char iso[64];
    int n = 0, y, x;
    FILE *fp;
    size_t rowBytes = (size_t)m->w * (m->bits16 ? 2 : 1), total;
    uint8_t *row;
    static const char *bayerName[] = { "RGGB", "BGGR", "GRBG", "GBRG" };

    memset(hdr, ' ', sizeof hdr);
    card_raw(hdr, &n, "SIMPLE  =                    T / file conforms to FITS standard");
    card_int(hdr, &n, "BITPIX", m->bits16 ? 16 : 8, "bits per pixel");
    card_int(hdr, &n, "NAXIS", 2, "number of axes");
    card_int(hdr, &n, "NAXIS1", m->w, "width");
    card_int(hdr, &n, "NAXIS2", m->h, "height");
    if (m->bits16) {
        card_int(hdr, &n, "BZERO", 32768, "unsigned 16-bit data");
        card_int(hdr, &n, "BSCALE", 1, "");
    }
    ticks_to_iso(ticks, iso, sizeof iso);
    card_str(hdr, &n, "DATE-OBS", iso, "UTC frame time");
    card_dbl(hdr, &n, "EXPTIME", m->expUs / 1e6, "exposure (s)");
    card_int(hdr, &n, "GAIN", m->gain, "camera gain");
    card_int(hdr, &n, "OFFSET", m->offset, "camera offset");
    card_dbl(hdr, &n, "CCD-TEMP", m->tempX10 / 10.0, "sensor temperature (C)");
    card_int(hdr, &n, "XBINNING", m->bin, "");
    card_int(hdr, &n, "YBINNING", m->bin, "");
    card_dbl(hdr, &n, "XPIXSZ", g.info.PixelSize * m->bin, "pixel size incl. binning (um)");
    card_dbl(hdr, &n, "YPIXSZ", g.info.PixelSize * m->bin, "pixel size incl. binning (um)");
    card_str(hdr, &n, "INSTRUME", g.info.Name, "camera");
    if (g.telescope[0]) card_str(hdr, &n, "TELESCOP", g.telescope, "telescope");
    if (g.focalMm > 0) card_int(hdr, &n, "FOCALLEN", g.focalMm, "focal length (mm)");
    if (g.filter[0]) card_str(hdr, &n, "FILTER", g.filter, "filter");
    if (g.info.IsColorCam) {
        card_str(hdr, &n, "BAYERPAT", bayerName[g.info.BayerPattern & 3], "colour filter array");
        card_int(hdr, &n, "XBAYROFF", 0, "");
        card_int(hdr, &n, "YBAYROFF", 0, "");
    }
    card_str(hdr, &n, "IMAGETYP", m->imagetyp, "frame type");
    if (m->ncombine > 0) card_int(hdr, &n, "NCOMBINE", m->ncombine, "frames averaged");
    card_str(hdr, &n, "ROWORDER", "TOP-DOWN", "");
    card_str(hdr, &n, "SWCREATE", "QBCap / libqbcap", "");
    card_raw(hdr, &n, "END");

    mkdir_parents(path);
    fp = fopen(path, "wb");
    if (!fp) { snprintf(g.err, sizeof g.err, "cannot create %.180s: %s", path, strerror(errno)); return -1; }
    fwrite(hdr, 1, (n <= 36) ? 2880 : 5760, fp);

    row = (uint8_t *)malloc(rowBytes);
    if (!row) { fclose(fp); return fail_msg("out of memory (fits row)"); }
    for (y = 0; y < m->h; y++) {
        const uint8_t *src = data + (size_t)y * rowBytes;
        if (m->bits16) {      /* FITS: big-endian signed, value - 32768 */
            const uint16_t *s16 = (const uint16_t *)src;
            for (x = 0; x < m->w; x++) {
                uint16_t v = (uint16_t)(s16[x] ^ 0x8000);
                row[2 * x] = (uint8_t)(v >> 8);
                row[2 * x + 1] = (uint8_t)v;
            }
            fwrite(row, 1, rowBytes, fp);
        } else {
            fwrite(src, 1, rowBytes, fp);
        }
    }
    free(row);
    total = rowBytes * m->h;
    if (total % 2880) {
        static const uint8_t zeros[2880];
        fwrite(zeros, 1, 2880 - total % 2880, fp);
    }
    if (fclose(fp) != 0) { snprintf(g.err, sizeof g.err, "write failed %.200s", path); return -1; }
    return 0;
}

static int write_fits(const char *path, const uint8_t *data, int64_t ticks)
{
    FitsMeta m = live_meta();
    return write_fits_m(path, data, ticks, &m);
}

/* ------------------------------------------------------------------ */
/* SER writer                                                          */
/* ------------------------------------------------------------------ */
static void ser_header(uint8_t *h, int frames, int64_t firstTicks)
{
    /* SER colour IDs: MONO 0, RGGB 8, GRBG 9, GBRG 10, BGGR 11 */
    static const int serBayer[] = { 8, 11, 9, 10 };   /* ASI order: RG, BG, GR, GB */
    struct tm lt;
    time_t now = time(NULL);
    long gmtoff;
    memset(h, 0, 178);
    memcpy(h, "LUCAM-RECORDER", 14);
    put_le32(h + 14, 0);
    put_le32(h + 18, g.info.IsColorCam ? serBayer[g.info.BayerPattern & 3] : 0);
    put_le32(h + 22, 0);   /* 0 = little-endian 16-bit data, as FireCapture/SharpCap write it */
    put_le32(h + 26, g.fw);
    put_le32(h + 30, g.fh);
    put_le32(h + 34, g.bits16 ? 16 : 8);
    put_le32(h + 38, frames);
    snprintf((char *)h + 42, 40, "%s", "QBCap");
    snprintf((char *)h + 82, 40, "%.39s", g.info.Name);
    snprintf((char *)h + 122, 40, "%.39s", g.telescope);
    localtime_r(&now, &lt);
    gmtoff = lt.tm_gmtoff;
    put_le64(h + 162, firstTicks + (int64_t)gmtoff * 10000000LL);
    put_le64(h + 170, firstTicks);
}

/* ------------------------------------------------------------------ */
/* ring buffer                                                         */
/* ------------------------------------------------------------------ */
static void rec_push(const uint8_t *src)
{
    QCRec *r = &g.rec;
    int s;
    pthread_mutex_lock(&r->mx);
    if (!r->accepting) { pthread_mutex_unlock(&r->mx); return; }
    if (r->head - r->tail >= (unsigned long long)r->nslots) {
        r->dropped++;                       /* disk can't keep up */
        pthread_mutex_unlock(&r->mx);
        return;
    }
    s = (int)(r->head % r->nslots);
    pthread_mutex_unlock(&r->mx);

    memcpy(r->slot[s], src, g.frameBytes);  /* slot s is not visible to the writer yet */
    r->ts[s] = utc_ticks();

    pthread_mutex_lock(&r->mx);
    r->head++;
    if (r->maxFrames > 0 && r->head >= (unsigned long long)r->maxFrames) r->accepting = 0;
    if (r->maxSecs > 0 && now_sec() - r->t0 >= r->maxSecs) r->accepting = 0;
    pthread_cond_signal(&r->cv);
    pthread_mutex_unlock(&r->mx);
}

static void *rec_thread(void *arg)
{
    QCRec *r = &g.rec;
    (void)arg;
    for (;;) {
        int s;
        pthread_mutex_lock(&r->mx);
        while (r->tail == r->head && r->accepting)
            pthread_cond_wait(&r->cv, &r->mx);
        if (r->tail == r->head && !r->accepting) { pthread_mutex_unlock(&r->mx); break; }
        s = (int)(r->tail % r->nslots);
        pthread_mutex_unlock(&r->mx);

        if (!r->ioError) {
            if (r->format == 0) {
                if (fwrite(r->slot[s], 1, g.frameBytes, r->fp) != g.frameBytes) {
                    snprintf(g.err, sizeof g.err, "SER write failed (disk full?): %s", strerror(errno));
                    r->ioError = 1;
                } else {
                    if (r->written >= r->tsCap) {
                        int nc = r->tsCap ? r->tsCap * 2 : 4096;
                        int64_t *nt = (int64_t *)realloc(r->tsAll, sizeof(int64_t) * (size_t)nc);
                        if (nt) { r->tsAll = nt; r->tsCap = nc; }
                    }
                    if (r->written < r->tsCap) r->tsAll[r->written] = r->ts[s];
                }
            } else {
                char fn[1100];
                snprintf(fn, sizeof fn, "%s_%05d.fits", r->path, r->written + 1);
                if (write_fits(fn, r->slot[s], r->ts[s]) != 0) r->ioError = 1;
            }
        }

        pthread_mutex_lock(&r->mx);
        r->tail++;
        if (!r->ioError) { r->written++; r->bytesWritten += (double)g.frameBytes; }
        if (r->ioError) r->accepting = 0;
        pthread_mutex_unlock(&r->mx);
    }

    if (r->format == 0 && r->fp) {          /* finish SER: timestamps trailer + real frame count */
        uint8_t h[178];
        int i;
        if (!r->ioError && r->tsAll) {
            for (i = 0; i < r->written; i++) {
                uint8_t b[8];
                put_le64(b, r->tsAll[i]);
                fwrite(b, 1, 8, r->fp);
            }
        }
        ser_header(h, r->written, r->written ? r->tsAll[0] : utc_ticks());
        fseek(r->fp, 0, SEEK_SET);
        fwrite(h, 1, 178, r->fp);
        fclose(r->fp);
        r->fp = NULL;
    }
    r->active = 0;
    return NULL;
}

static void rec_free(void)
{
    QCRec *r = &g.rec;
    int i;
    for (i = 0; i < REC_MAX_SLOTS; i++) { free(r->slot[i]); r->slot[i] = NULL; }
    free(r->tsAll); r->tsAll = NULL; r->tsCap = 0;
}

/*
 * Start recording.
 *   path      : SER -> full file name;  FITS -> base name (_00001.fits ... appended)
 *   format    : 0 = SER, 1 = FITS
 *   maxFrames : stop after this many frames (0 = no limit)
 *   maxSecs   : stop after this many seconds (0 = no limit)
 */
int qc_record_start(const char *path, int format, int maxFrames, int maxSecs)
{
    QCRec *r = &g.rec;
    int i;
    unsigned long long n;
    if (!g.open) return fail_msg("no camera open");
    if (!g.run) return fail_msg("start live video before recording");
    if (r->active || r->threadLive) qc_record_stop();

    n = REC_MAX_BYTES / g.frameBytes;
    if (n > REC_MAX_SLOTS) n = REC_MAX_SLOTS;
    if (n < 4) n = 4;
    for (i = 0; i < (int)n; i++) {
        r->slot[i] = (uint8_t *)malloc(g.frameBytes);
        if (!r->slot[i]) {
            if (i < 4) { rec_free(); return fail_msg("out of memory for record buffer"); }
            n = (unsigned long long)i;
            break;
        }
    }
    r->nslots = (int)n;
    r->format = format ? 1 : 0;
    r->head = r->tail = 0;
    r->written = 0; r->dropped = 0; r->bytesWritten = 0; r->ioError = 0;
    r->maxFrames = maxFrames > 0 ? maxFrames : 0;
    r->maxSecs = maxSecs > 0 ? maxSecs : 0;
    snprintf(r->path, sizeof r->path, "%s", path);
    mkdir_parents(r->path);

    if (r->format == 0) {
        uint8_t h[178];
        r->fp = fopen(r->path, "wb");
        if (!r->fp) {
            snprintf(g.err, sizeof g.err, "cannot create %.180s: %s", r->path, strerror(errno));
            rec_free();
            return -98;
        }
        setvbuf(r->fp, NULL, _IOFBF, 8 * 1024 * 1024);
        ser_header(h, 0, utc_ticks());                  /* rewritten at the end */
        fwrite(h, 1, 178, r->fp);
    }

    lucky_reset();
    r->t0 = now_sec();
    r->active = 1;
    r->accepting = 1;
    if (pthread_create(&r->thr, NULL, rec_thread, NULL)) {
        r->accepting = 0; r->active = 0;
        if (r->fp) { fclose(r->fp); r->fp = NULL; }
        rec_free();
        return fail_msg("could not start writer thread");
    }
    r->threadLive = 1;
    return 0;
}

/* stop accepting frames, let the writer finish what is buffered, close the file */
void qc_record_stop(void)
{
    QCRec *r = &g.rec;
    if (!r->threadLive) return;
    pthread_mutex_lock(&r->mx);
    r->accepting = 0;
    pthread_cond_broadcast(&r->cv);
    pthread_mutex_unlock(&r->mx);
    pthread_join(r->thr, NULL);
    r->threadLive = 0;
    rec_free();
}

/*
 * written    : frames saved to disk
 * bufPct     : how full the RAM buffer is (0-100) - climbing = disk too slow
 * dropped    : frames lost because the buffer was full
 * mbWritten  : megabytes written
 * active     : 1 while recording/draining, 0 when finished (limit reached / stopped / error)
 * returns <0 if the recording stopped because of a disk error
 */
int qc_record_status(int *written, int *bufPct, int *dropped, int *mbWritten, int *active)
{
    QCRec *r = &g.rec;
    unsigned long long q;
    pthread_mutex_lock(&r->mx);
    q = r->head - r->tail;
    *written = r->written;
    *bufPct = r->nslots ? (int)(q * 100 / (unsigned long long)r->nslots) : 0;
    *dropped = r->dropped;
    *mbWritten = (int)(r->bytesWritten / 1048576.0);
    *active = r->active;
    pthread_mutex_unlock(&r->mx);
    if (!r->active && r->threadLive) qc_record_stop();   /* finished by itself: tidy up */
    return r->ioError ? -1 : 0;
}

/* save the newest frame as a single FITS file */
int qc_snapshot(const char *path)
{
    uint8_t *copy;
    int src, rc;
    if (!g.open || !g.buf[0]) return fail_msg("no camera open");
    copy = (uint8_t *)malloc(g.frameBytes);
    if (!copy) return fail_msg("out of memory (snapshot)");
    pthread_mutex_lock(&g.mx);
    if (g.readySeq == 0) { pthread_mutex_unlock(&g.mx); free(copy); return fail_msg("no frame captured yet"); }
    src = (g.readySeq != g.frontSeq) ? g.ready : g.front;
    memcpy(copy, g.buf[src], g.frameBytes);
    pthread_mutex_unlock(&g.mx);
    rc = write_fits(path, copy, utc_ticks());
    free(copy);
    return rc;
}

/* ------------------------------------------------------------------ */
/* calibration: master dark / master flat                              */
/* Masters are kept in the 16-bit domain (RAW8 values are x256).        */
/* They are applied to the PREVIEW only - recorded files stay raw so    */
/* stacking software (Siril, AutoStakkert) can calibrate them itself.   */
/* ------------------------------------------------------------------ */
typedef struct {
    int loaded, w, h, expUs, gain, tempX10, bin, n;
    uint16_t *data;            /* mean frame                    */
    float    *inv;             /* flat only: mean(flat) / flat  */
} QCMaster;

static struct {
    QCMaster m[2];             /* 0 = dark, 1 = flat */
    int darkOn, flatOn;
    int useDark, useFlat;      /* resolved per preview: on + loaded + size matches */
    volatile int accActive, accDone;
    int accType, accTarget, accW, accH;
    uint32_t *sum;
    FitsMeta accMeta;
    char accPath[1024];
} cal;

/* called from the capture thread for every frame while a master is being built */
static void cal_accumulate(const uint8_t *f)
{
    size_t i, n;
    if (!cal.accActive || cal.accDone >= cal.accTarget) return;
    if (g.fw != cal.accW || g.fh != cal.accH) {
        snprintf(g.err, sizeof g.err, "frame size changed while building master - cancelled");
        cal.accActive = 0;
        return;
    }
    n = (size_t)g.fw * g.fh;
    if (g.bits16) {
        const uint16_t *p = (const uint16_t *)f;
        for (i = 0; i < n; i++) cal.sum[i] += p[i];
    } else {
        for (i = 0; i < n; i++) cal.sum[i] += (uint32_t)f[i] << 8;
    }
    cal.accDone++;
}

static pthread_mutex_t calMx = PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP;   /* masters vs stacker thread */

static void master_free(QCMaster *m)
{
    pthread_mutex_lock(&calMx);
    free(m->data); free(m->inv);
    m->data = NULL; m->inv = NULL; m->loaded = 0;
    pthread_mutex_unlock(&calMx);
}

/* flat -> per-pixel correction. If a dark of the same size is loaded, it is
   subtracted first so the camera offset/bias doesn't skew the vignetting fix. */
static int flat_make_inverse(QCMaster *m)
{
    size_t i, n = (size_t)m->w * m->h;
    double mean = 0;
    const QCMaster *d = &cal.m[0];
    int useDark = d->loaded && d->w == m->w && d->h == m->h;
    m->inv = (float *)malloc(sizeof(float) * n);
    if (!m->inv) return fail_msg("out of memory (flat)");
    for (i = 0; i < n; i++) {
        double v = (double)m->data[i] - (useDark ? d->data[i] : 0);
        m->inv[i] = (float)(v < 1 ? 1 : v);      /* temporarily hold flat - dark */
        mean += m->inv[i];
    }
    mean /= (double)n;
    for (i = 0; i < n; i++) {
        double r = mean / m->inv[i];
        if (r > 8.0) r = 8.0;           /* dead / very dark pixels: don't explode */
        m->inv[i] = (float)r;
    }
    return 0;
}

/* a new dark arrived: rebuild the flat's correction so it uses (flat - dark) */
static void refresh_flat(void)
{
    QCMaster *f = &cal.m[1];
    if (!f->loaded) return;
    free(f->inv); f->inv = NULL;
    if (flat_make_inverse(f) != 0) master_free(f);
}

/* type 0 = dark, 1 = flat. Averages nframes live frames, then saves to path. */
int qc_master_start(int type, int nframes, const char *path)
{
    size_t n;
    if (!g.open) return fail_msg("no camera open");
    if (!g.run) return fail_msg("start live video first");
    if (cal.accActive) return fail_msg("a master is already being captured");
    if (type < 0 || type > 1) return fail_msg("bad master type");
    if (nframes < 1) nframes = 1;
    if (nframes > 256) nframes = 256;
    n = (size_t)g.fw * g.fh;
    free(cal.sum);
    cal.sum = (uint32_t *)calloc(n, sizeof(uint32_t));
    if (!cal.sum) return fail_msg("out of memory (master sum)");
    refresh_auto_values();
    cal.accType = type; cal.accTarget = nframes; cal.accDone = 0;
    cal.accW = g.fw; cal.accH = g.fh;
    cal.accMeta = live_meta();
    cal.accMeta.bits16 = 1;
    cal.accMeta.ncombine = nframes;
    cal.accMeta.imagetyp = type ? "Master Flat" : "Master Dark";
    snprintf(cal.accPath, sizeof cal.accPath, "%s", path);
    cal.accActive = 1;                  /* last: capture thread starts adding now */
    return 0;
}

void qc_master_cancel(void)
{
    cal.accActive = 0;
}

/*
 * Poll from QB64. done/total = progress.
 * Returns 1 while capturing, 0 idle, 2 = just finished (master built, saved, now loaded),
 * <0 on error (message in qc_last_error).
 */
int qc_master_status(int *done, int *total)
{
    QCMaster *m;
    size_t i, n;
    int rc;
    *done = cal.accDone;
    *total = cal.accTarget;
    if (!cal.accActive) {
        if (cal.sum && cal.accDone < cal.accTarget) { free(cal.sum); cal.sum = NULL; return -1; }
        return 0;
    }
    if (cal.accDone < cal.accTarget) return 1;

    cal.accActive = 0;                  /* capture thread stops adding */
    pthread_mutex_lock(&calMx);
    m = &cal.m[cal.accType];
    master_free(m);
    n = (size_t)cal.accW * cal.accH;
    m->data = (uint16_t *)malloc(n * sizeof(uint16_t));
    if (!m->data) { free(cal.sum); cal.sum = NULL; pthread_mutex_unlock(&calMx); return fail_msg("out of memory (master)"); }
    for (i = 0; i < n; i++) m->data[i] = (uint16_t)((cal.sum[i] + cal.accTarget / 2) / cal.accTarget);
    free(cal.sum); cal.sum = NULL;
    m->w = cal.accW; m->h = cal.accH;
    m->expUs = cal.accMeta.expUs; m->gain = cal.accMeta.gain;
    m->tempX10 = cal.accMeta.tempX10; m->bin = cal.accMeta.bin; m->n = cal.accTarget;
    if (cal.accType == 1 && flat_make_inverse(m) != 0) { master_free(m); pthread_mutex_unlock(&calMx); return -1; }
    m->loaded = 1;
    if (cal.accType == 0) refresh_flat();
    pthread_mutex_unlock(&calMx);
    rc = write_fits_m(cal.accPath, (const uint8_t *)m->data, utc_ticks(), &cal.accMeta);
    return rc == 0 ? 2 : -2;            /* -2: master is loaded but the file was not saved */
}

/* read a 16-bit (or 8-bit) FITS master back in */
int qc_master_load(int type, const char *path)
{
    FILE *fp;
    char blk[2880], card[81];
    int k, end = 0, w = 0, h = 0, bitpix = 0, gain = 0, bin = 1, ncomb = 0;
    double bzero = 0, exps = 0, temp = 0;
    size_t i, n;
    QCMaster *m;
    if (type < 0 || type > 1) return fail_msg("bad master type");
    fp = fopen(path, "rb");
    if (!fp) { snprintf(g.err, sizeof g.err, "cannot open %.200s", path); return -1; }
    while (!end) {
        if (fread(blk, 1, 2880, fp) != 2880) { fclose(fp); return fail_msg("not a FITS file (short header)"); }
        for (k = 0; k < 36 && !end; k++) {
            memcpy(card, blk + k * 80, 80); card[80] = 0;
            if (!strncmp(card, "END", 3) && (card[3] == ' ' || card[3] == 0)) { end = 1; break; }
            if (card[8] != '=') continue;
            if (!strncmp(card, "NAXIS1  ", 8)) w = atoi(card + 10);
            else if (!strncmp(card, "NAXIS2  ", 8)) h = atoi(card + 10);
            else if (!strncmp(card, "BITPIX  ", 8)) bitpix = atoi(card + 10);
            else if (!strncmp(card, "BZERO   ", 8)) bzero = atof(card + 10);
            else if (!strncmp(card, "EXPTIME ", 8)) exps = atof(card + 10);
            else if (!strncmp(card, "GAIN    ", 8)) gain = atoi(card + 10);
            else if (!strncmp(card, "CCD-TEMP", 8)) temp = atof(card + 10);
            else if (!strncmp(card, "XBINNING", 8)) bin = atoi(card + 10);
            else if (!strncmp(card, "NCOMBINE", 8)) ncomb = atoi(card + 10);
        }
    }
    if (w <= 0 || h <= 0 || (bitpix != 16 && bitpix != 8)) { fclose(fp); return fail_msg("unsupported FITS (need 8 or 16-bit 2D image)"); }
    m = &cal.m[type];
    pthread_mutex_lock(&calMx);
    master_free(m);
    n = (size_t)w * h;
    m->data = (uint16_t *)malloc(n * sizeof(uint16_t));
    if (!m->data) { fclose(fp); pthread_mutex_unlock(&calMx); return fail_msg("out of memory (master)"); }
    if (bitpix == 16) {
        uint8_t b[2];
        for (i = 0; i < n; i++) {
            long v;
            if (fread(b, 1, 2, fp) != 2) { fclose(fp); master_free(m); pthread_mutex_unlock(&calMx); return fail_msg("FITS data cut short"); }
            v = (long)(int16_t)((b[0] << 8) | b[1]) + (long)bzero;
            if (v < 0) v = 0;
            if (v > 65535) v = 65535;
            m->data[i] = (uint16_t)v;
        }
    } else {
        int c;
        for (i = 0; i < n; i++) {
            if ((c = fgetc(fp)) == EOF) { fclose(fp); master_free(m); pthread_mutex_unlock(&calMx); return fail_msg("FITS data cut short"); }
            m->data[i] = (uint16_t)(c << 8);
        }
    }
    fclose(fp);
    m->w = w; m->h = h; m->expUs = (int)(exps * 1e6 + 0.5); m->gain = gain;
    m->tempX10 = (int)(temp * 10 + (temp < 0 ? -0.5 : 0.5)); m->bin = bin; m->n = ncomb;
    if (type == 1 && flat_make_inverse(m) != 0) { master_free(m); pthread_mutex_unlock(&calMx); return -1; }
    m->loaded = 1;
    if (type == 0) refresh_flat();
    pthread_mutex_unlock(&calMx);
    return 0;
}

int qc_master_info(int type, int *w, int *h, int *expUs, int *gain, int *tempX10, int *nframes)
{
    QCMaster *m;
    if (type < 0 || type > 1) return 0;
    m = &cal.m[type];
    *w = m->w; *h = m->h; *expUs = m->expUs; *gain = m->gain; *tempX10 = m->tempX10; *nframes = m->n;
    return m->loaded;
}

void qc_master_clear(int type)
{
    pthread_mutex_lock(&calMx);
    if (type >= 0 && type <= 1) master_free(&cal.m[type]);
    if (type == 0) refresh_flat();
    pthread_mutex_unlock(&calMx);
}

int qc_calib_set(int darkOn, int flatOn)
{
    cal.darkOn = darkOn ? 1 : 0;
    cal.flatOn = flatOn ? 1 : 0;
    return 0;
}

/* 1 if the master is loaded and the same size as the current frames */
int qc_master_fits(int type)
{
    QCMaster *m = &cal.m[type & 1];
    return m->loaded && m->w == g.fw && m->h == g.fh;
}

static inline uint32_t calv(const uint8_t *f, size_t i)
{
    int32_t v = g.bits16 ? ((const uint16_t *)f)[i] : ((int32_t)f[i] << 8);
    if (cal.useDark) { v -= cal.m[0].data[i]; if (v < 0) v = 0; }
    if (cal.useFlat) {
        float t = (float)v * cal.m[1].inv[i];
        v = t > 65535.0f ? 65535 : (int32_t)t;
    }
    return (uint32_t)v;
}

/* ------------------------------------------------------------------ */
/* sharpness scoring (CPU or GPU) + lucky imaging                       */
/* ------------------------------------------------------------------ */
static struct {
    void *h;                    /* dlopen handle for libqbgpu.so */
    int   active;               /* 1 = scores computed on the GPU */
    int   devCount, memMB, ccMaj, ccMin, dev;
    char  name[128];
    int        (*count)(void);
    int        (*init)(int, char *, int, int *, int *, int *);
    int        (*score)(const void *, int, int, int, double *, double *, long long *);
    void       (*shutdown)(void);
    const char*(*error)(void);
} gpu;

static int (*gpu_stack_alloc)(int, int, int);
static int (*gpu_stack_add)(float *const *, float, float, float, float, int, float, int *);
static int (*gpu_stack_fetch)(float **, float **, uint16_t **);
static void (*gpu_stack_free)(void);

#define Q_HIST 256
#define Q_WIN  200
static struct {
    volatile int on;            /* compute a score for every frame (graph / focus) */
    volatile int luckyOn;       /* gate recording on the score */
    int   keepPct;
    float hist[Q_HIST];         /* score history for the graph (ring) */
    int   histPos, histN;
    float win[Q_WIN];           /* recent scores for the keep threshold (ring) */
    int   winPos, winN;
    volatile float last, thresh;
    volatile int kept, rejected;
    volatile double msPerFrame; /* time spent scoring the last frame */
} q = { .keepPct = 25 };

/* identical maths to k_score in qbgpu.cu, in double precision */
static float score_cpu(const uint8_t *f, int w, int h, int b16)
{
    int W2 = w / 2, H2 = h / 2, x, y;
    double L = 0, E = 0;
    long long n = (long long)(W2 - 2) * (H2 - 2);
    const uint16_t *p16 = (const uint16_t *)f;
    if (n <= 0) return 0;
#define SP(xx, yy) (b16 ? ((double)p16[(size_t)(2*(yy))*w + 2*(xx)] + p16[(size_t)(2*(yy))*w + 2*(xx) + 1] \
                         + p16[(size_t)(2*(yy)+1)*w + 2*(xx)] + p16[(size_t)(2*(yy)+1)*w + 2*(xx) + 1]) \
                       : 256.0 * ((double)f[(size_t)(2*(yy))*w + 2*(xx)] + f[(size_t)(2*(yy))*w + 2*(xx) + 1] \
                         + f[(size_t)(2*(yy)+1)*w + 2*(xx)] + f[(size_t)(2*(yy)+1)*w + 2*(xx) + 1]))
    for (y = 1; y < H2 - 1; y++) {
        for (x = 1; x < W2 - 1; x++) {
            double c = SP(x, y);
            double lap = 4.0 * c - SP(x - 1, y) - SP(x + 1, y) - SP(x, y - 1) - SP(x, y + 1);
            L += c;
            E += lap * lap;
        }
    }
#undef SP
    L /= (double)n; E /= (double)n;
    return (float)(1000.0 * E / (L * L + 1.0));
}

static float score_frame(const uint8_t *f, int w, int h, int b16)
{
    if (gpu.active) {
        double L, E; long long n;
        if (gpu.score(f, w, h, b16, &L, &E, &n) == 0 && n > 0) {
            L /= (double)n; E /= (double)n;
            return (float)(1000.0 * E / (L * L + 1.0));
        }
        snprintf(g.err, sizeof g.err, "GPU scoring failed, using CPU: %.180s", gpu.error());
        gpu.active = 0;                 /* fall back for the rest of the session */
    }
    return score_cpu(f, w, h, b16);
}

static int cmp_float(const void *a, const void *b)
{
    float x = *(const float *)a, y = *(const float *)b;
    return (x > y) - (x < y);
}

/* called from the capture thread before a frame is offered to the recorder */
static void quality_frame(const uint8_t *f)
{
    double t0 = now_sec();
    float s = score_frame(f, g.fw, g.fh, g.bits16);
    q.msPerFrame = (now_sec() - t0) * 1000.0;
    q.last = s;
    q.hist[q.histPos] = s;
    q.histPos = (q.histPos + 1) % Q_HIST;
    if (q.histN < Q_HIST) q.histN++;
}

/* returns 1 if this frame should be recorded */
static int lucky_gate(float s)
{
    float tmp[Q_WIN];
    int idx, keep;
    q.win[q.winPos] = s;
    q.winPos = (q.winPos + 1) % Q_WIN;
    if (q.winN < Q_WIN) q.winN++;
    if (q.winN < 20) {                  /* warm-up: learn the seeing first, keep nothing */
        return 0;
    } else {
        memcpy(tmp, q.win, sizeof(float) * q.winN);
        qsort(tmp, q.winN, sizeof(float), cmp_float);
        idx = (int)((long)q.winN * (100 - q.keepPct) / 100);
        if (idx >= q.winN) idx = q.winN - 1;
        q.thresh = tmp[idx];
        keep = s >= q.thresh;
    }
    if (keep) q.kept++; else q.rejected++;
    return keep;
}

static void lucky_reset(void)
{
    q.winN = 0; q.winPos = 0; q.kept = 0; q.rejected = 0; q.thresh = 0;
}

static void lib_dir(char *out, size_t n)
{
    Dl_info di;
    char *slash;
    out[0] = 0;
    if (dladdr((void *)lib_dir, &di) && di.dli_fname) {
        snprintf(out, n, "%s", di.dli_fname);
        slash = strrchr(out, '/');
        if (slash) slash[1] = 0; else out[0] = 0;
    }
}

/*
 * Load libqbgpu.so (next to libqbcap.so) and open CUDA device dev.
 * Returns 1 = GPU active, 0 = CPU fallback (reason in qc_last_error).
 */
int qc_gpu_init(int dev)
{
    char path[1100], dir[1024];
    if (gpu.active && gpu.dev == dev) return 1;
    if (gpu.active) { gpu.active = 0; gpu.shutdown(); }
    if (!gpu.h) {
        lib_dir(dir, sizeof dir);
        snprintf(path, sizeof path, "%slibqbgpu.so", dir);
        gpu.h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        if (!gpu.h) {
            snprintf(g.err, sizeof g.err, "no GPU library (%.200s) - using CPU", dlerror());
            return 0;
        }
        *(void **)&gpu.count    = dlsym(gpu.h, "qbg_device_count");
        *(void **)&gpu.init     = dlsym(gpu.h, "qbg_init");
        *(void **)&gpu.score    = dlsym(gpu.h, "qbg_score");
        *(void **)&gpu.shutdown = dlsym(gpu.h, "qbg_shutdown");
        *(void **)&gpu.error    = dlsym(gpu.h, "qbg_error");
        /* stacking functions are optional (older libqbgpu.so builds don't have them) */
        *(void **)&gpu_stack_alloc = dlsym(gpu.h, "qbg_stack_alloc");
        *(void **)&gpu_stack_add   = dlsym(gpu.h, "qbg_stack_add");
        *(void **)&gpu_stack_fetch = dlsym(gpu.h, "qbg_stack_fetch");
        *(void **)&gpu_stack_free  = dlsym(gpu.h, "qbg_stack_free");
        if (!gpu_stack_alloc || !gpu_stack_add || !gpu_stack_fetch || !gpu_stack_free)
            gpu_stack_alloc = NULL;
        if (!gpu.count || !gpu.init || !gpu.score || !gpu.shutdown || !gpu.error) {
            snprintf(g.err, sizeof g.err, "libqbgpu.so is incomplete - using CPU");
            dlclose(gpu.h); gpu.h = NULL;
            return 0;
        }
    }
    gpu.devCount = gpu.count();
    if (gpu.devCount <= 0) {
        snprintf(g.err, sizeof g.err, "no CUDA device found (%.180s) - using CPU", gpu.error());
        return 0;
    }
    if (gpu.init(dev, gpu.name, sizeof gpu.name, &gpu.memMB, &gpu.ccMaj, &gpu.ccMin) != 0) {
        snprintf(g.err, sizeof g.err, "%.200s - using CPU", gpu.error());
        return 0;
    }
    gpu.dev = dev;
    gpu.active = 1;
    return 1;
}

int qc_gpu_info(char *name, int len, int *memMB, int *ccX10, int *devCount)
{
    copy_str(name, len, gpu.active ? gpu.name : "CPU");
    *memMB = gpu.active ? gpu.memMB : 0;
    *ccX10 = gpu.active ? gpu.ccMaj * 10 + gpu.ccMin : 0;
    *devCount = gpu.devCount;
    return gpu.active;
}

/*
 * Score the same synthetic 1280x960 frame on CPU and GPU.
 * Returns 1 = match, 0 = mismatch, -1 = GPU not active. Scores x1000 out.
 */
int qc_gpu_selftest(int *cpuX1000, int *gpuX1000, int *gpuUs)
{
    const int w = 1280, h = 960;
    uint16_t *img = (uint16_t *)malloc(sizeof(uint16_t) * w * h);
    double L, E, t0;
    long long n;
    float c, gsc;
    int x, y, ok;
    if (!img) return fail_msg("out of memory (selftest)");
    for (y = 0; y < h; y++)
        for (x = 0; x < w; x++)
            img[(size_t)y * w + x] = (uint16_t)(8000 + 6000 * sin(x * 0.05) * cos(y * 0.07) + ((x * 7 + y * 13) % 97) * 20);
    c = score_cpu((const uint8_t *)img, w, h, 1);
    *cpuX1000 = (int)(c * 1000);
    if (!gpu.active) { free(img); *gpuX1000 = 0; *gpuUs = 0; return -1; }
    t0 = now_sec();
    if (gpu.score(img, w, h, 1, &L, &E, &n) != 0) {
        snprintf(g.err, sizeof g.err, "GPU self-test failed: %.180s", gpu.error());
        free(img);
        return 0;
    }
    *gpuUs = (int)((now_sec() - t0) * 1e6);
    L /= (double)n; E /= (double)n;
    gsc = (float)(1000.0 * E / (L * L + 1.0));
    *gpuX1000 = (int)(gsc * 1000);
    free(img);
    ok = fabs(gsc - c) <= 1e-3 * fabs(c) + 1e-6;
    if (!ok) snprintf(g.err, sizeof g.err, "GPU/CPU score mismatch: cpu %.4f gpu %.4f", c, gsc);
    return ok;
}

/* score every frame (for the sharpness graph / focusing) */
int qc_quality_enable(int on) { q.on = on ? 1 : 0; return 0; }

/* lucky imaging: when recording, keep only frames in the best keepPct % of recent ones */
int qc_lucky_set(int on, int keepPct)
{
    if (keepPct < 1) keepPct = 1;
    if (keepPct > 100) keepPct = 100;
    q.keepPct = keepPct;
    q.luckyOn = on ? 1 : 0;
    return 0;
}

int qc_lucky_stats(float *lastScore, float *thresh, int *kept, int *rejected, float *msPerFrame)
{
    *lastScore = q.last; *thresh = q.thresh; *kept = q.kept; *rejected = q.rejected;
    *msPerFrame = (float)q.msPerFrame;
    return q.histN;
}

/* copy up to n most recent scores, oldest first; returns how many */
int qc_score_history(float *out, int n)
{
    int cnt = q.histN < n ? q.histN : n, i;
    int start = (q.histPos - cnt + Q_HIST) % Q_HIST;
    for (i = 0; i < cnt; i++) out[i] = q.hist[(start + i) % Q_HIST];
    return cnt;
}

/* ------------------------------------------------------------------ */
/* live stacking                                                        */
/*  - stacker thread: calibrate -> stars -> align -> accumulate         */
/*  - mono: 1 plane at full size;  colour: R,G,B planes at half size    */
/*  - accumulate: running mean (Welford) or sigma-clip (kappa = 3)      */
/*  - the per-pixel accumulate runs on the GPU when libqbgpu is active  */
/* ------------------------------------------------------------------ */
typedef struct { float x, y, flux; } Star;
#define MAX_STARS 80

static struct {
    pthread_mutex_t mx;
    pthread_cond_t  cv;
    pthread_t thr;
    int threadLive;
    volatile int running;          /* capture thread offers frames */
    volatile int quit;
    /* mailbox: capture -> stacker */
    uint8_t *inbox, *work;
    size_t   boxCap;
    int      inboxFull;
    volatile int skipped;          /* frames that arrived while still busy */
    int      expUsIn, expUsWork;
    /* stack geometry (fixed when the stack starts) */
    int P, W, H, fw, fh, bits16, colour, bayer;
    float   *mean[3], *m2[3];
    uint16_t *cnt[3];
    float   *in[3];                /* calibrated planes of the frame being added */
    float   *lum;                  /* luminance for star detection (colour only) */
    int      mode;                 /* 0 = mean, 1 = sigma clip */
    float    kappa;
    int      hotFix;               /* remove single-pixel spikes before stacking */
    volatile int hotFixed;
    Star     ref[MAX_STARS];
    int      nRef;
    /* results */
    volatile int stacked, failed, lastStars, lastMatches, rejectedPx;
    volatile float lastDx, lastDy, lastRotDeg, lastRms;
    volatile double lastMs, expTotal;
    volatile int haveStack, viewStack, gpuStack;
    volatile int align;            /* 1 = align frames on stars, 0 = stack frames as they come */
    volatile unsigned version;     /* bumps after every stacked frame (display refresh) */
    char msg[160];
} stk = { .mx = PTHREAD_MUTEX_INITIALIZER, .cv = PTHREAD_COND_INITIALIZER, .kappa = 3.0f, .hotFix = 1, .align = 1 };

static void stack_free_buffers(void)
{
    int p;
    for (p = 0; p < 3; p++) {
        free(stk.mean[p]); free(stk.m2[p]); free(stk.cnt[p]); free(stk.in[p]);
        stk.mean[p] = stk.m2[p] = stk.in[p] = NULL; stk.cnt[p] = NULL;
    }
    free(stk.lum); stk.lum = NULL;
    free(stk.inbox); free(stk.work); stk.inbox = stk.work = NULL; stk.boxCap = 0;
}

/* ---- calibration + plane extraction ------------------------------- */
static inline float raw_cal(const uint8_t *f, size_t k, const uint16_t *dark, const float *flatInv)
{
    float v = stk.bits16 ? (float)((const uint16_t *)f)[k] : (float)(f[k] << 8);
    if (dark) v -= dark[k];
    if (flatInv) v *= flatInv[k];
    return v;
}

static void stack_extract(const uint8_t *f)
{
    size_t n = (size_t)stk.fw * stk.fh, i;
    int x, y, useD, useF;
    const QCMaster *d = &cal.m[0], *fl = &cal.m[1];
    pthread_mutex_lock(&calMx);
    useD = cal.darkOn && d->loaded && d->w == stk.fw && d->h == stk.fh;
    useF = cal.flatOn && fl->loaded && fl->w == stk.fw && fl->h == stk.fh && fl->inv;
    if (!stk.colour) {
        float *o = stk.in[0];
        for (i = 0; i < n; i++) {
            float v = stk.bits16 ? (float)((const uint16_t *)f)[i] : (float)(f[i] << 8);
            if (useD) v -= d->data[i];
            if (useF) v *= fl->inv[i];
            o[i] = v;
        }
        pthread_mutex_unlock(&calMx);
        return;
    }
    /* colour: calibrate each raw pixel, then 2x2 superpixel -> R, G (mean of two), B */
    {
        int rx, ry, bx, by, g1x, g1y, g2x, g2y;
        switch (stk.bayer) {
            case ASI_BAYER_RG: rx = 0; ry = 0; bx = 1; by = 1; g1x = 1; g1y = 0; g2x = 0; g2y = 1; break;
            case ASI_BAYER_BG: rx = 1; ry = 1; bx = 0; by = 0; g1x = 1; g1y = 0; g2x = 0; g2y = 1; break;
            case ASI_BAYER_GR: rx = 1; ry = 0; bx = 0; by = 1; g1x = 0; g1y = 0; g2x = 1; g2y = 1; break;
            default:           rx = 0; ry = 1; bx = 1; by = 0; g1x = 0; g1y = 0; g2x = 1; g2y = 1; break;
        }
#define RAWC(xx, yy) raw_cal(f, (size_t)(yy) * stk.fw + (xx), useD ? d->data : NULL, useF ? fl->inv : NULL)
        for (y = 0; y < stk.H; y++) {
            for (x = 0; x < stk.W; x++) {
                int cx = 2 * x, cy = 2 * y;
                size_t o = (size_t)y * stk.W + x;
                stk.in[0][o] = RAWC(cx + rx, cy + ry);
                stk.in[1][o] = 0.5f * (RAWC(cx + g1x, cy + g1y) + RAWC(cx + g2x, cy + g2y));
                stk.in[2][o] = RAWC(cx + bx, cy + by);
                stk.lum[o] = stk.in[0][o] + stk.in[1][o] + stk.in[2][o];
            }
        }
#undef RAWC
    }
    pthread_mutex_unlock(&calMx);
}

/* ---- star detection ------------------------------------------------ */
static int cmp_float_s(const void *a, const void *b)
{
    float x = *(const float *)a, y = *(const float *)b;
    return (x > y) - (x < y);
}

/* background median and noise sigma (MAD) from a sparse sample */
static void bg_noise(const float *L, size_t n, float *bg, float *sigma)
{
    enum { NS = 20000 };
    static __thread float s[NS], dev[NS];   /* per thread: stacker and solver both use this */
    size_t step = n / NS + 1, i;
    int k = 0, j;
    for (i = 0; i < n && k < NS; i += step) s[k++] = L[i];
    qsort(s, k, sizeof(float), cmp_float_s);
    *bg = s[k / 2];
    for (j = 0; j < k; j++) dev[j] = fabsf(s[j] - *bg);
    qsort(dev, k, sizeof(float), cmp_float_s);
    *sigma = 1.4826f * dev[k / 2];
    if (*sigma < 1.0f) *sigma = 1.0f;
}

static int detect_stars(const float *L, int W, int H, Star *out, int maxN)
{
    float bg, sigma, thr;
    int x, y, n = 0, dx, dy;
    bg_noise(L, (size_t)W * H, &bg, &sigma);
    thr = bg + 6.0f * sigma;
    for (y = 3; y < H - 3; y++) {
        const float *row = L + (size_t)y * W;
        for (x = 3; x < W - 3; x++) {
            float v = row[x], sum = 0, sx = 0, sy = 0, nb = 0;
            int isMax = 1;
            if (v < thr) continue;
            for (dy = -2; dy <= 2 && isMax; dy++)
                for (dx = -2; dx <= 2; dx++) {
                    float u = L[(size_t)(y + dy) * W + x + dx];
                    if ((dx || dy) && (u > v || (u == v && (dy < 0 || (dy == 0 && dx < 0))))) { isMax = 0; break; }
                }
            if (!isMax) continue;
            /* reject single-pixel spikes (hot pixels, cosmic rays): real stars spread light */
            for (dy = -1; dy <= 1; dy++)
                for (dx = -1; dx <= 1; dx++)
                    if (dx || dy) nb += L[(size_t)(y + dy) * W + x + dx] - bg;
            if (nb < 0.6f * (v - bg)) continue;
            for (dy = -2; dy <= 2; dy++)
                for (dx = -2; dx <= 2; dx++) {
                    float w = L[(size_t)(y + dy) * W + x + dx] - bg;
                    if (w <= 0) continue;
                    sum += w; sx += w * (x + dx); sy += w * (y + dy);
                }
            if (sum <= 0) continue;
            /* keep the brightest maxN (simple insertion) */
            if (n < maxN || sum > out[n - 1].flux) {
                Star st = { sx / sum, sy / sum, sum };
                int pos = (n < maxN) ? n++ : n - 1;
                while (pos > 0 && out[pos - 1].flux < st.flux) { out[pos] = out[pos - 1]; pos--; }
                out[pos] = st;
            }
        }
    }
    return n;
}

/* ---- hot pixel removal ----------------------------------------------
 * A pixel well above the background whose 8 neighbours are all much
 * darker is a hot pixel or cosmic-ray hit (stars spread over several
 * pixels). Replace it with the mean of its neighbours. Returns count.  */
static int fix_hot_pixels(float *L, int W, int H)
{
    float bg, sigma, thr;
    int x, y, n = 0, dx, dy;
    bg_noise(L, (size_t)W * H, &bg, &sigma);
    thr = bg + 5.0f * sigma;
    for (y = 1; y < H - 1; y++) {
        float *row = L + (size_t)y * W;
        for (x = 1; x < W - 1; x++) {
            float v = row[x], mx = -1e30f, sum = 0;
            if (v < thr) continue;
            for (dy = -1; dy <= 1; dy++)
                for (dx = -1; dx <= 1; dx++) {
                    float u;
                    if (!dx && !dy) continue;
                    u = L[(size_t)(y + dy) * W + x + dx];
                    sum += u;
                    if (u > mx) mx = u;
                }
            /* brightest neighbour holds less than a third of the spike above background */
            if (mx - bg < 0.33f * (v - bg)) { row[x] = sum / 8.0f; n++; }
        }
    }
    return n;
}

/* ---- alignment: rigid transform  cur = R(theta) * ref + t --------- */
static int fit_rigid(const Star *r, const Star *c, const int *m, int nr, float T[4], float *rms, int *nm)
{
    double rx = 0, ry = 0, cx = 0, cy = 0, sxx = 0, sxy = 0, th, a, b, err = 0;
    int i, k = 0;
    for (i = 0; i < nr; i++) if (m[i] >= 0) { rx += r[i].x; ry += r[i].y; cx += c[m[i]].x; cy += c[m[i]].y; k++; }
    if (k < 4) { *nm = k; return -1; }
    rx /= k; ry /= k; cx /= k; cy /= k;
    for (i = 0; i < nr; i++) if (m[i] >= 0) {
        double ax = r[i].x - rx, ay = r[i].y - ry, bx = c[m[i]].x - cx, by = c[m[i]].y - cy;
        sxx += ax * bx + ay * by;
        sxy += ax * by - ay * bx;
    }
    th = atan2(sxy, sxx);
    a = cos(th); b = sin(th);
    T[0] = (float)a; T[1] = (float)b;
    T[2] = (float)(cx - (a * rx - b * ry));
    T[3] = (float)(cy - (b * rx + a * ry));
    for (i = 0; i < nr; i++) if (m[i] >= 0) {
        double px = a * r[i].x - b * r[i].y + T[2], py = b * r[i].x + a * r[i].y + T[3];
        err += (px - c[m[i]].x) * (px - c[m[i]].x) + (py - c[m[i]].y) * (py - c[m[i]].y);
    }
    *rms = (float)sqrt(err / k);
    *nm = k;
    return 0;
}

static void match_with(const Star *r, int nr, const Star *c, int nc, const float T[4], float tol, int *m)
{
    int i, j;
    for (i = 0; i < nr; i++) {
        float px = T[0] * r[i].x - T[1] * r[i].y + T[2];
        float py = T[1] * r[i].x + T[0] * r[i].y + T[3];
        float best = tol * tol;
        m[i] = -1;
        for (j = 0; j < nc; j++) {
            float dx = c[j].x - px, dy = c[j].y - py, d2 = dx * dx + dy * dy;
            if (d2 < best) { best = d2; m[i] = j; }
        }
    }
}

static int align_frame(const Star *r, int nr, const Star *c, int nc, float T[4], int *matches, float *rms)
{
    enum { NV = 40 };
    float tx[NV * NV], ty[NV * NV];
    int m[MAX_STARS];
    int a = nr < NV ? nr : NV, b = nc < NV ? nc : NV, i, j, k = 0, best = -1, bestCnt = 0, pass, nm = 0;
    /* 1) vote for the translation using all star pairs */
    for (i = 0; i < a; i++)
        for (j = 0; j < b; j++) { tx[k] = c[j].x - r[i].x; ty[k] = c[j].y - r[i].y; k++; }
    for (i = 0; i < k; i++) {
        int cnt = 0;
        for (j = 0; j < k; j++) {
            float dx = tx[j] - tx[i], dy = ty[j] - ty[i];
            if (dx * dx + dy * dy < 6.25f) cnt++;
        }
        if (cnt > bestCnt) { bestCnt = cnt; best = i; }
    }
    if (best < 0 || bestCnt < 4) { *matches = bestCnt; *rms = 0; return -1; }
    T[0] = 1; T[1] = 0; T[2] = tx[best]; T[3] = ty[best];
    /* 2) match + refit twice, tightening the tolerance */
    for (pass = 0; pass < 3; pass++) {
        match_with(r, nr, c, nc, T, pass == 0 ? 5.0f : 2.5f, m);
        if (fit_rigid(r, c, m, nr, T, rms, &nm) != 0) { *matches = nm; return -1; }
    }
    *matches = nm;
    return (nm >= 5 && *rms < 1.5f) ? 0 : -1;
}

/* ---- accumulate (CPU) - must match k_stack_add in qbgpu.cu --------- */
static int cpu_accumulate(float *const *in, int P, int W, int H, float **mean, float **m2,
                          uint16_t **cnt, const float T[4], int mode, float kappa)
{
    int p, x, y, rejected = 0;
    for (p = 0; p < P; p++) {
        const float *src = in[p];
        for (y = 0; y < H; y++) {
            for (x = 0; x < W; x++) {
                float u = T[0] * x - T[1] * y + T[2];
                float v = T[1] * x + T[0] * y + T[3];
                int x0, y0;
                float fx, fy, s, mu, d;
                size_t i = (size_t)y * W + x;
                unsigned n;
                if (u < 0.0f || v < 0.0f || u > W - 1.001f || v > H - 1.001f) continue;
                x0 = (int)u; y0 = (int)v; fx = u - x0; fy = v - y0;
                {
                    const float *q = src + (size_t)y0 * W + x0;
                    s = (q[0] * (1 - fx) + q[1] * fx) * (1 - fy) + (q[W] * (1 - fx) + q[W + 1] * fx) * fy;
                }
                n = cnt[p][i];
                mu = mean[p][i];
                if (mode == 1 && n >= 5) {
                    float sd = sqrtf(m2[p][i] / (float)(n - 1));
                    if (fabsf(s - mu) > kappa * sd + 1.0f) { rejected++; continue; }
                }
                if (n >= 65535) continue;
                n++;
                d = s - mu;
                mu += d / (float)n;
                m2[p][i] += d * (s - mu);
                mean[p][i] = mu;
                cnt[p][i] = (uint16_t)n;
            }
        }
    }
    return rejected;
}

/* ---- the stacker thread -------------------------------------------- */

static void stack_process(const uint8_t *f, int expUs)
{
    Star cur[MAX_STARS];
    int nc, matches = 0, rej = 0;
    float T[4] = { 1, 0, 0, 0 }, rms = 0;
    double t0 = now_sec();
    const float *L;

    stack_extract(f);
    if (stk.hotFix) {
        int p, nh = 0;
        for (p = 0; p < stk.P; p++) nh += fix_hot_pixels(stk.in[p], stk.W, stk.H);
        if (stk.colour) {
            size_t i, n = (size_t)stk.W * stk.H;
            for (i = 0; i < n; i++) stk.lum[i] = stk.in[0][i] + stk.in[1][i] + stk.in[2][i];
        }
        stk.hotFixed = nh;
    }
    if (!stk.align) {
        /* no alignment: add the frame where it is (T stays the identity) */
        stk.lastStars = 0;
    } else {
    L = stk.colour ? stk.lum : stk.in[0];
    nc = detect_stars(L, stk.W, stk.H, cur, MAX_STARS);
    stk.lastStars = nc;

    if (stk.nRef == 0) {
        if (nc < 8) {
            stk.failed++;
            snprintf(stk.msg, sizeof stk.msg, "only %d stars - need 8 to start (longer exposure / focus?)", nc);
            return;
        }
        memcpy(stk.ref, cur, sizeof(Star) * nc);
        stk.nRef = nc;
        matches = nc;
    } else if (align_frame(stk.ref, stk.nRef, cur, nc, T, &matches, &rms) != 0) {
        stk.failed++;
        stk.lastMatches = matches;
        snprintf(stk.msg, sizeof stk.msg, "frame not aligned (%d stars, %d matched) - skipped", nc, matches);
        return;
    }
    }

    if (stk.gpuStack) {
        if (gpu_stack_add(stk.in, T[0], T[1], T[2], T[3], stk.mode, stk.kappa, &rej) != 0 ||
            gpu_stack_fetch(stk.mean, stk.m2, stk.cnt) != 0) {
            /* host copies hold the stack as of the previous frame: carry on with the CPU */
            snprintf(g.err, sizeof g.err, "GPU stacking failed, continuing on CPU: %.150s", gpu.error());
            stk.gpuStack = 0;
            rej = cpu_accumulate(stk.in, stk.P, stk.W, stk.H, stk.mean, stk.m2, stk.cnt, T, stk.mode, stk.kappa);
        }
    } else {
        rej = cpu_accumulate(stk.in, stk.P, stk.W, stk.H, stk.mean, stk.m2, stk.cnt, T, stk.mode, stk.kappa);
    }

    stk.rejectedPx = rej;
    stk.lastMatches = matches;
    stk.lastRms = rms;
    stk.lastDx = T[2]; stk.lastDy = T[3];
    stk.lastRotDeg = (float)(atan2(T[1], T[0]) * 180.0 / M_PI);
    stk.expTotal += expUs / 1e6;
    stk.stacked++;
    stk.haveStack = 1;
    stk.lastMs = (now_sec() - t0) * 1000.0;
    stk.version++;
    snprintf(stk.msg, sizeof stk.msg, "stacked %d", stk.stacked);
}

static void *stack_thread(void *arg)
{
    (void)arg;
    for (;;) {
        uint8_t *t;
        int e;
        pthread_mutex_lock(&stk.mx);
        while (!stk.inboxFull && !stk.quit) pthread_cond_wait(&stk.cv, &stk.mx);
        if (stk.quit) { pthread_mutex_unlock(&stk.mx); break; }
        t = stk.work; stk.work = stk.inbox; stk.inbox = t;   /* take the frame */
        e = stk.expUsIn;
        stk.inboxFull = 0;
        pthread_mutex_unlock(&stk.mx);
        stack_process(stk.work, e);
    }
    return NULL;
}

/* called by the capture thread for every frame while stacking */
static void stack_offer(const uint8_t *f)
{
    if (pthread_mutex_trylock(&stk.mx) != 0) { stk.skipped++; return; }
    if (stk.inboxFull || g.fw != stk.fw || g.fh != stk.fh) {
        stk.skipped++;
    } else {
        memcpy(stk.inbox, f, g.frameBytes);
        stk.expUsIn = g.expUs;
        stk.inboxFull = 1;
        pthread_cond_signal(&stk.cv);
    }
    pthread_mutex_unlock(&stk.mx);
}

static void stack_clear_data(void)
{
    int p;
    size_t n = (size_t)stk.W * stk.H;
    for (p = 0; p < stk.P; p++) {
        memset(stk.mean[p], 0, n * sizeof(float));
        memset(stk.m2[p], 0, n * sizeof(float));
        memset(stk.cnt[p], 0, n * sizeof(uint16_t));
    }
    stk.nRef = 0; stk.stacked = 0; stk.failed = 0; stk.skipped = 0;
    stk.expTotal = 0; stk.haveStack = 0; stk.rejectedPx = 0;
    stk.lastDx = stk.lastDy = stk.lastRotDeg = stk.lastRms = 0;
    stk.version++;
    stk.msg[0] = 0;
}

void qc_stack_stop(void);

/* mode 0 = mean, 1 = sigma clip */
int qc_stack_start(int mode)
{
    int p;
    size_t n;
    if (!g.open) return fail_msg("no camera open");
    if (!g.run) return fail_msg("start live video first");
    qc_stack_stop();
    stack_free_buffers();
    stk.fw = g.fw; stk.fh = g.fh; stk.bits16 = g.bits16;
    stk.colour = g.info.IsColorCam ? 1 : 0;
    stk.bayer = g.info.BayerPattern;
    stk.P = stk.colour ? 3 : 1;
    stk.W = stk.colour ? g.fw / 2 : g.fw;
    stk.H = stk.colour ? g.fh / 2 : g.fh;
    n = (size_t)stk.W * stk.H;
    for (p = 0; p < stk.P; p++) {
        stk.mean[p] = (float *)calloc(n, sizeof(float));
        stk.m2[p]   = (float *)calloc(n, sizeof(float));
        stk.cnt[p]  = (uint16_t *)calloc(n, sizeof(uint16_t));
        stk.in[p]   = (float *)malloc(n * sizeof(float));
        if (!stk.mean[p] || !stk.m2[p] || !stk.cnt[p] || !stk.in[p]) { stack_free_buffers(); return fail_msg("out of memory (stack)"); }
    }
    if (stk.colour) {
        stk.lum = (float *)malloc(n * sizeof(float));
        if (!stk.lum) { stack_free_buffers(); return fail_msg("out of memory (stack)"); }
    }
    stk.boxCap = g.frameBytes;
    stk.inbox = (uint8_t *)malloc(stk.boxCap);
    stk.work = (uint8_t *)malloc(stk.boxCap);
    if (!stk.inbox || !stk.work) { stack_free_buffers(); return fail_msg("out of memory (stack)"); }
    stk.mode = mode ? 1 : 0;
    stack_clear_data();
    stk.gpuStack = 0;
    if (gpu.active && gpu_stack_alloc && gpu_stack_alloc(stk.P, stk.W, stk.H) == 0) stk.gpuStack = 1;
    stk.inboxFull = 0;
    stk.quit = 0;
    if (pthread_create(&stk.thr, NULL, stack_thread, NULL)) { stack_free_buffers(); return fail_msg("could not start stacker thread"); }
    stk.threadLive = 1;
    stk.viewStack = 1;
    stk.running = 1;
    return stk.gpuStack ? 1 : 0;          /* 1 = stacking on the GPU */
}

/* stop adding frames; the stack stays for viewing and saving */
void qc_stack_stop(void)
{
    stk.running = 0;
    if (!stk.threadLive) return;
    pthread_mutex_lock(&stk.mx);
    stk.quit = 1;
    pthread_cond_broadcast(&stk.cv);
    pthread_mutex_unlock(&stk.mx);
    pthread_join(stk.thr, NULL);
    stk.threadLive = 0;
}

/* throw the stack away and start again with the next frame (keeps running) */
int qc_stack_reset(void)
{
    int wasRunning = stk.running;
    if (!stk.P) return 0;
    stk.running = 0;
    pthread_mutex_lock(&stk.mx);              /* wait for the stacker to finish its frame */
    stack_clear_data();
    if (stk.gpuStack) gpu_stack_alloc(stk.P, stk.W, stk.H);
    pthread_mutex_unlock(&stk.mx);
    stk.running = wasRunning;
    return 0;
}

int qc_stack_mode(int mode) { stk.mode = mode ? 1 : 0; return 0; }
int qc_stack_align(int on)
{
    stk.align = on ? 1 : 0;      /* takes effect on the next frame; the reference stars are kept */
    return 0;
}
int qc_stack_hotfix(int on) { stk.hotFix = on ? 1 : 0; return stk.hotFixed; }
int qc_stack_view(int onStack) { stk.viewStack = onStack ? 1 : 0; return 0; }

int qc_stack_stats(int *stacked, int *failed, int *skipped, int *stars, int *matches,
                   float *dx, float *dy, float *rotDeg, float *rms, float *ms, float *expSec)
{
    *stacked = stk.stacked; *failed = stk.failed; *skipped = stk.skipped;
    *stars = stk.lastStars; *matches = stk.lastMatches;
    *dx = stk.lastDx; *dy = stk.lastDy; *rotDeg = stk.lastRotDeg; *rms = stk.lastRms;
    *ms = (float)stk.lastMs; *expSec = (float)stk.expTotal;
    return stk.running ? (stk.gpuStack ? 2 : 1) : 0;    /* 0 idle, 1 CPU, 2 GPU */
}

int qc_stack_message(char *buf, int len) { copy_str(buf, len, stk.msg); return 0; }

/* copy one stack plane (mean) for tests / analysis */
int qc_stack_get_plane(int p, float *out, int maxN)
{
    size_t n = (size_t)stk.W * stk.H;
    if (!stk.haveStack || p < 0 || p >= stk.P) return 0;
    if ((size_t)maxN < n) n = (size_t)maxN;
    memcpy(out, stk.mean[p], n * sizeof(float));
    return (int)n;
}

/* save the stack as 32-bit float FITS (colour: 3-plane RGB cube) */
int qc_stack_save(const char *path)
{
    char hdr[2880 * 2], iso[64], t[100];
    int n = 0, p;
    size_t i, np = (size_t)stk.W * stk.H, total;
    FILE *fp;
    uint8_t *buf;
    if (!stk.haveStack) return fail_msg("nothing stacked yet");
    memset(hdr, ' ', sizeof hdr);
    card_raw(hdr, &n, "SIMPLE  =                    T / file conforms to FITS standard");
    card_int(hdr, &n, "BITPIX", -32, "32-bit float");
    card_int(hdr, &n, "NAXIS", stk.P == 3 ? 3 : 2, "number of axes");
    card_int(hdr, &n, "NAXIS1", stk.W, "width");
    card_int(hdr, &n, "NAXIS2", stk.H, "height");
    if (stk.P == 3) card_int(hdr, &n, "NAXIS3", 3, "R, G, B");
    ticks_to_iso(utc_ticks(), iso, sizeof iso);
    card_str(hdr, &n, "DATE", iso, "UTC file written");
    card_dbl(hdr, &n, "EXPTIME", stk.expTotal, "total exposure (s)");
    card_int(hdr, &n, "NCOMBINE", stk.stacked, "frames stacked");
    card_raw(hdr, &n, stk.align ? "STKALIGN=                    T / frames aligned on stars"
                                : "STKALIGN=                    F / frames stacked without alignment");
    card_str(hdr, &n, "STACKMOD", stk.mode ? "sigma clip" : "mean", "stacking method");
    card_int(hdr, &n, "GAIN", g.gainVal, "camera gain");
    card_dbl(hdr, &n, "CCD-TEMP", g.tempX10 / 10.0, "sensor temperature (C)");
    card_str(hdr, &n, "INSTRUME", g.info.Name, "camera");
    if (g.telescope[0]) card_str(hdr, &n, "TELESCOP", g.telescope, "telescope");
    if (g.focalMm > 0) card_int(hdr, &n, "FOCALLEN", g.focalMm, "focal length (mm)");
    if (g.filter[0]) card_str(hdr, &n, "FILTER", g.filter, "filter");
    card_str(hdr, &n, "IMAGETYP", "Light Stack", "frame type");
    snprintf(t, sizeof t, "COMMENT values are in the 16-bit range (0-65535)%s", stk.colour ? ", 2x2 superpixel RGB" : "");
    card_raw(hdr, &n, t);
    card_str(hdr, &n, "SWCREATE", "QBCap / libqbcap", "");
    card_raw(hdr, &n, "END");
    mkdir_parents(path);
    fp = fopen(path, "wb");
    if (!fp) { snprintf(g.err, sizeof g.err, "cannot create %.180s: %s", path, strerror(errno)); return -1; }
    fwrite(hdr, 1, (n <= 36) ? 2880 : 5760, fp);
    buf = (uint8_t *)malloc((size_t)stk.W * 4);
    if (!buf) { fclose(fp); return fail_msg("out of memory (save)"); }
    for (p = 0; p < stk.P; p++) {
        for (i = 0; i < np; i += stk.W) {
            int x;
            for (x = 0; x < stk.W; x++) {
                union { float f; uint32_t u; } v;
                v.f = stk.mean[p][i + x];
                buf[4 * x] = (uint8_t)(v.u >> 24); buf[4 * x + 1] = (uint8_t)(v.u >> 16);
                buf[4 * x + 2] = (uint8_t)(v.u >> 8); buf[4 * x + 3] = (uint8_t)v.u;
            }
            fwrite(buf, 1, (size_t)stk.W * 4, fp);
        }
    }
    free(buf);
    total = np * 4 * stk.P;
    if (total % 2880) { static const uint8_t z[2880]; fwrite(z, 1, 2880 - total % 2880, fp); }
    if (fclose(fp) != 0) { snprintf(g.err, sizeof g.err, "write failed %.200s", path); return -1; }
    return 0;
}


/* ---- stack display -------------------------------------------------- */
static unsigned stkShownVersion = 0xFFFFFFFFu;

static inline uint32_t sv16(float v)
{
    if (v <= 0.0f) return 0;
    if (v >= 65535.0f) return 65535;
    return (uint32_t)v;
}

static int stack_viewable(void)
{
    return stk.viewStack && stk.haveStack && stk.fw == g.fw && stk.fh == g.fh;
}

static void stack_histogram(void)
{
    size_t n = (size_t)stk.W * stk.H, i, step = n / 200000 + 1;
    memset(g.hist, 0, sizeof g.hist);
    for (i = 0; i < n; i += step) {
        float v = stk.mean[0][i];
        if (stk.P == 3) v = (stk.mean[0][i] + stk.mean[1][i] + stk.mean[2][i]) / 3.0f;
        g.hist[sv16(v) >> 8]++;
    }
}

/* draw the stack instead of the live frame (same geometry rules as qc_get_preview) */
static int render_stack(uint32_t *dst, int imgW, int imgH, int dx, int dy, int dw, int dh,
                        int sx, int sy, int sw, int sh, int force)
{
    int x, y, sc = stk.colour ? 2 : 1;
    int *xmap;
    unsigned ver = stk.version;
    if (ver == stkShownVersion && !force) return 0;
    stkShownVersion = ver;
    stack_histogram();
    if (sx < 0) sx = 0;
    if (sy < 0) sy = 0;
    if (sw <= 0 || sx + sw > stk.fw) sw = stk.fw - sx;
    if (sh <= 0 || sy + sh > stk.fh) sh = stk.fh - sy;
    if (dx < 0) dx = 0;
    if (dy < 0) dy = 0;
    if (dx + dw > imgW) dw = imgW - dx;
    if (dy + dh > imgH) dh = imgH - dy;
    if (dw <= 0 || dh <= 0 || sw <= 0 || sh <= 0) return 0;
    xmap = (int *)malloc(sizeof(int) * (size_t)dw);
    if (!xmap) return 0;
    for (x = 0; x < dw; x++) {
        int fx = (sx + (int)(((long long)x * sw) / dw)) / sc;
        xmap[x] = fx < stk.W ? fx : stk.W - 1;
    }
    for (y = 0; y < dh; y++) {
        int py = (sy + (int)(((long long)y * sh) / dh)) / sc;
        uint32_t *out = dst + (size_t)(dy + y) * imgW + dx;
        size_t row;
        if (py >= stk.H) py = stk.H - 1;
        row = (size_t)py * stk.W;
        if (stk.P == 3) {
            for (x = 0; x < dw; x++) {
                size_t i = row + xmap[x];
                uint32_t r = g.lutR16[sv16(stk.mean[0][i])], gg = g.lut16[sv16(stk.mean[1][i])], b = g.lutB16[sv16(stk.mean[2][i])];
                out[x] = 0xFF000000u | (r << 16) | (gg << 8) | b;
            }
        } else {
            for (x = 0; x < dw; x++) {
                uint32_t v = g.lut16[sv16(stk.mean[0][row + xmap[x]])];
                out[x] = 0xFF000000u | (v << 16) | (v << 8) | v;
            }
        }
    }
    free(xmap);
    return 1;
}

/*
 * Suggest a stretch for what is on screen (stack or live frame):
 * black just under the sky background, white near the brightest stars,
 * gamma so the background sits at about a quarter brightness.
 * Values are in slider units (black/white 0-255, gamma x100).
 */
int qc_auto_stretch(int *black, int *white, int *gammaX100)
{
    enum { NS = 40000 };
    static float s[NS], dev[NS];
    int k = 0, j;
    float med, sig, hi, b, w, t, gm;
    if (stack_viewable()) {
        size_t n = (size_t)stk.W * stk.H, i, step = n / NS + 1;
        for (i = 0; i < n && k < NS; i += step) {
            float v = stk.mean[0][i];
            if (stk.P == 3) v = (stk.mean[0][i] + stk.mean[1][i] + stk.mean[2][i]) / 3.0f;
            s[k++] = v;
        }
    } else {
        const uint8_t *f;
        size_t n = (size_t)g.fw * g.fh, i, step;
        if (!g.open || !g.haveFront) return fail_msg("no image yet");
        f = g.buf[g.front];
        step = n / NS + 1;
        for (i = 0; i < n && k < NS; i += step)
            s[k++] = g.bits16 ? (float)((const uint16_t *)f)[i] : (float)(f[i] << 8);
    }
    if (k < 100) return fail_msg("no image yet");
    qsort(s, k, sizeof(float), cmp_float_s);
    med = s[k / 2];
    hi = s[(int)(k * 0.9995)];
    for (j = 0; j < k; j++) dev[j] = fabsf(s[j] - med);
    qsort(dev, k, sizeof(float), cmp_float_s);
    sig = 1.4826f * dev[k / 2];
    if (sig < 16) sig = 16;
    b = med - 2.8f * sig;
    if (b < 0) b = 0;
    w = hi;
    if (w < med + 20 * sig) w = med + 20 * sig;
    if (w > 65535) w = 65535;
    *black = (int)(b / 257.0f);
    *white = (int)(w / 257.0f + 0.999f);
    if (*white <= *black) *white = *black + 1;
    if (*white > 255) *white = 255;
    t = (med - *black * 257.0f) / ((*white - *black) * 257.0f);
    if (t <= 0.001f) t = 0.001f;
    if (t >= 0.999f) t = 0.999f;
    gm = 100.0f * logf(t) / logf(0.25f);
    if (gm < 10) gm = 10;
    if (gm > 300) gm = 300;
    *gammaX100 = (int)(gm + 0.5f);
    return 0;
}
/* ------------------------------------------------------------------ */
/* capture thread                                                      */
/* ------------------------------------------------------------------ */
/* step 11 guider (defined at the end) */
static volatile int gd_on;
static void guide_frame(const uint8_t *f);

/* a complete frame is in g.buf[g.back] (capture thread):
   hand it to recording / quality / darks / stacking / guiding, then swap */
static void cap_frame_arrived(double *t0, int *n0)
{
    int t;
    double t1;
    int keepIt = 1;
    if (q.on || (q.luckyOn && g.rec.accepting)) quality_frame(g.buf[g.back]);
    if (q.luckyOn && g.rec.accepting) keepIt = lucky_gate(q.last);
    if (g.rec.accepting && keepIt) rec_push(g.buf[g.back]);   /* before the swap: back is ours */
    if (cal.accActive) cal_accumulate(g.buf[g.back]);
    if (stk.running) stack_offer(g.buf[g.back]);
    if (gd_on) guide_frame(g.buf[g.back]);
    pthread_mutex_lock(&g.mx);
    t = g.back; g.back = g.ready; g.ready = t;
    g.readySeq++;
    pthread_mutex_unlock(&g.mx);
    g.captured++;
    (*n0)++;
    t1 = now_sec();
    if (t1 - *t0 >= 1.0) {
        g.fpsX10 = (int)(*n0 * 10.0 / (t1 - *t0) + 0.5);
        *t0 = t1; *n0 = 0;
    }
}

static void *cap_thread(void *arg)
{
    double t0 = now_sec();
    int n0 = 0;
    (void)arg;
    while (g.run) {
        /* wait in short steps (a timeout just means "not ready yet"), so Stop
           answers at once even during a 10-minute exposure */
        int waitMs = g.expUs / 500 + 500;
        if (waitMs > 500) waitMs = 500;
        int e = ASIGetVideoData(g.id, g.buf[g.back], (long)g.frameBytes, waitMs);
        if (e == ASI_SUCCESS) {
            cap_frame_arrived(&t0, &n0);
        } else if (e == ASI_ERROR_TIMEOUT) {
            if (now_sec() - t0 > 3.0 + g.expUs / 1e6) g.fpsX10 = 0;
        } else {
            fail(e, "ASIGetVideoData");
            usleep(20000);
        }
    }
    return NULL;
}

int qc_start_video(void)
{
    int e;
    if (!g.open) return fail_msg("no camera open");
    if (g.run) return 0;
    if (!g.buf[0]) { e = alloc_buffers(); if (e) return e; }
    if (g3.active) {
        g.captured = 0; g.fpsX10 = 0;
        g.run = 1;
        if (pthread_create(&g.thr, NULL, g3_cap_thread, NULL)) { g.run = 0; return fail_msg("could not start capture thread"); }
        return 0;
    }
    if (qh.active) {
        g.captured = 0; g.fpsX10 = 0;
        g.run = 1;
        if (pthread_create(&g.thr, NULL, qh_cap_thread, NULL)) { g.run = 0; return fail_msg("could not start capture thread"); }
        return 0;
    }
    if (uv.active) {
        e = uv_streamon();
        if (e) return e;
        g.captured = 0; g.fpsX10 = 0;
        g.run = 1;
        if (pthread_create(&g.thr, NULL, uv_cap_thread, NULL)) { g.run = 0; uv_streamoff(); return fail_msg("could not start capture thread"); }
        return 0;
    }
    e = ASIStartVideoCapture(g.id);
    if (e) return fail(e, "ASIStartVideoCapture");
    g.captured = 0; g.fpsX10 = 0;
    g.run = 1;
    if (pthread_create(&g.thr, NULL, cap_thread, NULL)) {
        g.run = 0;
        ASIStopVideoCapture(g.id);
        return fail_msg("could not start capture thread");
    }
    return 0;
}

void qc_stop(void)
{
    if (!g.run) return;
    g.run = 0;
    if (qh.active) qh_cancel();    /* QHY: end a long exposure so the thread can return */
    pthread_join(g.thr, NULL);     /* returns within 0.5 s (short GetVideoData waits; a G3 download may take ~2 s) */
    if (uv.active) uv_streamoff();
    else if (!g3.active && !qh.active) ASIStopVideoCapture(g.id);
    g.fpsX10 = 0;
}

int qc_is_running(void) { return g.run; }

/* ------------------------------------------------------------------ */
/* preview                                                             */
/* ------------------------------------------------------------------ */
static void build_histogram(const uint8_t *f)
{
    int x, y;
    memset(g.hist, 0, sizeof g.hist);
    for (y = 0; y < g.fh; y += 4) {
        if (g.bits16) {
            const uint16_t *row = (const uint16_t *)f + (size_t)y * g.fw;
            for (x = 0; x < g.fw; x += 4) g.hist[row[x] >> 8]++;
        } else {
            const uint8_t *row = f + (size_t)y * g.fw;
            for (x = 0; x < g.fw; x += 4) g.hist[row[x]]++;
        }
    }
}

static inline uint8_t pix(const uint8_t *f, int x, int y)
{
    size_t i = (size_t)y * g.fw + x;
    if (cal.useDark || cal.useFlat) return g.lut16[calv(f, i)];
    return g.bits16 ? g.lut16[((const uint16_t *)f)[i]] : g.lut8[f[i]];
}

static inline uint8_t pixc(const uint8_t *f, int x, int y, const uint8_t *l8, const uint8_t *l16)
{
    size_t i = (size_t)y * g.fw + x;
    if (cal.useDark || cal.useFlat) return l16[calv(f, i)];
    return g.bits16 ? l16[((const uint16_t *)f)[i]] : l8[f[i]];
}

/*
 * Draw the newest frame into a QB64 32-bit image.
 *   bgra       : _MemImage(img).OFFSET   (imgW x imgH, 4 bytes/pixel)
 *   dx,dy,dw,dh: destination rectangle inside that image
 *   sx,sy,sw,sh: source rectangle in frame pixels (zoom / pan)
 *   force      : redraw even if no new frame arrived
 * Returns 1 if drawn, 0 if nothing new, <0 on error.
 */
int qc_get_preview(void *bgra, int imgW, int imgH,
                   int dx, int dy, int dw, int dh,
                   int sx, int sy, int sw, int sh, int force)
{
    uint32_t *dst = (uint32_t *)bgra;
    const uint8_t *f;
    int isNew = 0, x, y, *xmap;
    int colour, rx, ry, bx, by, gx, gy;

    if (!g.open || !g.buf[0] || !g.lut16) return 0;
    if (stack_viewable()) return render_stack(dst, imgW, imgH, dx, dy, dw, dh, sx, sy, sw, sh, force);

    pthread_mutex_lock(&g.mx);
    if (g.readySeq != g.frontSeq) {
        int t = g.front; g.front = g.ready; g.ready = t;
        g.frontSeq = g.readySeq;
        g.haveFront = 1;
        isNew = 1;
    }
    pthread_mutex_unlock(&g.mx);
    if (!g.haveFront || (!isNew && !force)) return 0;
    f = g.buf[g.front];
    if (isNew) build_histogram(f);

    /* clip */
    if (sx < 0) sx = 0;
    if (sy < 0) sy = 0;
    if (sw <= 0 || sx + sw > g.fw) sw = g.fw - sx;
    if (sh <= 0 || sy + sh > g.fh) sh = g.fh - sy;
    if (dx < 0) dx = 0;
    if (dy < 0) dy = 0;
    if (dx + dw > imgW) dw = imgW - dx;
    if (dy + dh > imgH) dh = imgH - dy;
    if (dw <= 0 || dh <= 0 || sw <= 0 || sh <= 0) return 0;

    /* calibration applies only when the master matches this frame size */
    cal.useDark = cal.darkOn && qc_master_fits(0);
    cal.useFlat = cal.flatOn && qc_master_fits(1);

    /* Bayer offsets inside each 2x2 cell */
    colour = g.debayer && g.info.IsColorCam;
    switch (g.info.BayerPattern) {
        case ASI_BAYER_RG: rx = 0; ry = 0; bx = 1; by = 1; gx = 1; gy = 0; break;
        case ASI_BAYER_BG: rx = 1; ry = 1; bx = 0; by = 0; gx = 1; gy = 0; break;
        case ASI_BAYER_GR: rx = 1; ry = 0; bx = 0; by = 1; gx = 0; gy = 0; break;
        default:           rx = 0; ry = 1; bx = 1; by = 0; gx = 0; gy = 0; break;
    }

    xmap = (int *)malloc(sizeof(int) * (size_t)dw);
    if (!xmap) return fail_msg("out of memory (xmap)");
    for (x = 0; x < dw; x++) xmap[x] = sx + (int)(((long long)x * sw) / dw);

    for (y = 0; y < dh; y++) {
        int fy = sy + (int)(((long long)y * sh) / dh);
        uint32_t *out = dst + (size_t)(dy + y) * imgW + dx;
        if (colour) {
            int cy = fy & ~1;
            if (cy + 1 >= g.fh) cy = g.fh - 2;
            for (x = 0; x < dw; x++) {
                int cx = xmap[x] & ~1;
                uint32_t r, gg, b;
                if (cx + 1 >= g.fw) cx = g.fw - 2;
                r  = pixc(f, cx + rx, cy + ry, g.lutR8, g.lutR16);
                gg = pix(f, cx + gx, cy + gy);
                b  = pixc(f, cx + bx, cy + by, g.lutB8, g.lutB16);
                out[x] = 0xFF000000u | (r << 16) | (gg << 8) | b;
            }
        } else {
            for (x = 0; x < dw; x++) {
                uint32_t v = pix(f, xmap[x], fy);
                out[x] = 0xFF000000u | (v << 16) | (v << 8) | v;
            }
        }
    }
    free(xmap);
    return 1;
}

int qc_get_histogram(int *bins256)
{
    memcpy(bins256, g.hist, sizeof g.hist);
    return 0;
}

/* in auto mode the camera changes exposure/gain itself: read the real values
   so file headers and master metadata are correct */
static void refresh_auto_values(void)
{
    long v; ASI_BOOL a;
    if (!g.open || g3.active || uv.active || qh.active) return;
    if (g.expAuto && ASIGetControlValue(g.id, ASI_EXPOSURE, &v, &a) == ASI_SUCCESS && v > 0) g.expUs = (int)v;
    if (g.gainAuto && ASIGetControlValue(g.id, ASI_GAIN, &v, &a) == ASI_SUCCESS) g.gainVal = (int)v;
}

/* captured frames, dropped frames, fps*10, sensor temp*10 (temp read max 1/sec) */
int qc_stats(int *captured, int *dropped, int *fpsX10, int *tempX10)
{
    int d = 0;
    if (!g.open) { *captured = *dropped = *fpsX10 = *tempX10 = 0; return -1; }
    if (uv.active || qh.active) {   /* no temperature sensor, no drop counter */
        *captured = g.captured; *dropped = 0; *fpsX10 = g.fpsX10; *tempX10 = 0;
        return 0;
    }
    if (g3.active) {
        if (!g.run) g3_service(0, 0);
        g.tempX10 = g3.tempX10;
        *captured = g.captured; *dropped = 0; *fpsX10 = g.fpsX10; *tempX10 = g.tempX10;
        return 0;
    }
    ASIGetDroppedFrames(g.id, &d);
    if (now_sec() - g.tempTime >= 1.0) {
        long v = 0; ASI_BOOL a;
        refresh_auto_values();
        if (ASIGetControlValue(g.id, ASI_TEMPERATURE, &v, &a) == ASI_SUCCESS) g.tempX10 = (int)v;
        g.tempTime = now_sec();
    }
    *captured = g.captured;
    *dropped = d;
    *fpsX10 = g.fpsX10;
    *tempX10 = g.tempX10;
    return 0;
}

/* ------------------------------------------------------------------ */
/* ZWO EFW filter wheel                                                */
/* ------------------------------------------------------------------ */
static struct { int open, id, slots; char name[64]; } efw;

static const char *efw_err_text(int e)
{
    static const char *t[] = { "success", "invalid index", "invalid id", "invalid value",
        "wheel removed (udev rule installed?)", "wheel is moving", "wheel in error state",
        "general error", "not supported", "wheel closed" };
    if (e >= 0 && e < (int)(sizeof t / sizeof t[0])) return t[e];
    return "unknown error";
}

static int efw_fail(int e, const char *where)
{
    snprintf(g.err, sizeof g.err, "%s: %s (EFW %d)", where, efw_err_text(e), e);
    return -(e ? e : 99);
}

int qc_efw_count(void) { return EFWGetNum(); }

/* open wheel number idx (0 = first). Waits up to ~5 s while the wheel detects its slots. */
int qc_efw_open(int idx)
{
    int e, tries;
    EFW_INFO info;
    if (efw.open) return 0;
    if (EFWGetNum() <= idx) {
        snprintf(g.err, sizeof g.err, "no ZWO filter wheel found (%d on USB)", EFWGetNum());
        return -1;
    }
    e = EFWGetID(idx, &efw.id);
    if (e) return efw_fail(e, "EFWGetID");
    e = EFWOpen(efw.id);
    if (e) return efw_fail(e, "EFWOpen");
    for (tries = 0; tries < 50; tries++) {        /* slot detection right after connect */
        e = EFWGetProperty(efw.id, &info);
        if (e != EFW_ERROR_MOVING) break;
        usleep(100000);
    }
    if (e) { EFWClose(efw.id); return efw_fail(e, "EFWGetProperty"); }
    efw.slots = info.slotNum;
    snprintf(efw.name, sizeof efw.name, "%s", info.Name);
    efw.open = 1;
    return 0;
}

int qc_efw_info(char *name, int len, int *slots)
{
    if (!efw.open) { copy_str(name, len, ""); *slots = 0; return -1; }
    copy_str(name, len, efw.name);
    *slots = efw.slots;
    return 0;
}

/* slot is 0-based */
int qc_efw_set(int slot)
{
    int e;
    if (!efw.open) return fail_msg("filter wheel not open");
    if (slot < 0 || slot >= efw.slots) return fail_msg("filter slot out of range");
    e = EFWSetPosition(efw.id, slot);
    if (e) return efw_fail(e, "EFWSetPosition");
    return 0;
}

/* 0-based slot, -1 while moving, -2 on error / not open */
int qc_efw_get(void)
{
    int pos = -2, e;
    if (!efw.open) return -2;
    e = EFWGetPosition(efw.id, &pos);
    if (e == EFW_ERROR_MOVING) return -1;
    if (e) { efw_fail(e, "EFWGetPosition"); return -2; }
    return pos;                                  /* the SDK also reports -1 while moving */
}

int qc_efw_calibrate(void)
{
    int e;
    if (!efw.open) return fail_msg("filter wheel not open");
    e = EFWCalibrate(efw.id);
    if (e) return efw_fail(e, "EFWCalibrate");
    return 0;
}

void qc_efw_close(void)
{
    if (!efw.open) return;
    EFWClose(efw.id);
    efw.open = 0;
}

/*
 * Stack 4 synthetic frames with different shifts/rotations on CPU and GPU
 * (mean and sigma-clip) and compare. Returns 1 = match, 0 = mismatch,
 * -1 = GPU stacking not available, -2 = busy (a live stack is running on the GPU).
 */
int qc_gpu_stack_selftest(float *maxDiff)
{
    const int W = 640, H = 480;
    size_t n = (size_t)W * H, i;
    float *in, *cm, *c2, *gm, *g2;
    uint16_t *cc, *gc;
    int f, x, y, rej, ok = 1, mode;
    float worst = 0;
    *maxDiff = 0;
    if (!gpu.active || !gpu_stack_alloc) return -1;
    if (stk.gpuStack && stk.threadLive) return -2;
    in = (float *)malloc(n * 4); cm = (float *)calloc(n, 4); c2 = (float *)calloc(n, 4);
    gm = (float *)malloc(n * 4); g2 = (float *)malloc(n * 4);
    cc = (uint16_t *)calloc(n, 2); gc = (uint16_t *)malloc(n * 2);
    if (!in || !cm || !c2 || !gm || !g2 || !cc || !gc) { ok = -1; goto done; }
    for (mode = 0; mode <= 1 && ok == 1; mode++) {
        memset(cm, 0, n * 4); memset(c2, 0, n * 4); memset(cc, 0, n * 2);
        if (gpu_stack_alloc(1, W, H) != 0) { ok = -1; break; }
        for (f = 0; f < 8; f++) {
            float th = 0.002f * f, T[4];
            T[0] = cosf(th); T[1] = sinf(th); T[2] = 1.7f * f; T[3] = -0.9f * f;
            for (y = 0; y < H; y++)
                for (x = 0; x < W; x++)
                    in[(size_t)y * W + x] = 1000.0f + 500.0f * sinf(x * 0.03f + f) * cosf(y * 0.05f)
                                          + (float)(((x * 131 + y * 71 + f * 997) % 211) - 105) * 4.0f
                                          + ((x == 300 && y == 200 && f == 6) ? 30000.0f : 0.0f);   /* one outlier */
            cpu_accumulate(&in, 1, W, H, &cm, &c2, &cc, T, mode, 3.0f);
            if (gpu_stack_add(&in, T[0], T[1], T[2], T[3], mode, 3.0f, &rej) != 0) { ok = -1; break; }
        }
        if (ok != 1) break;
        if (gpu_stack_fetch(&gm, &g2, &gc) != 0) { ok = -1; break; }
        for (i = 0; i < n; i++) {
            float d = fabsf(gm[i] - cm[i]);
            if (gc[i] != cc[i]) d = 1e9f;
            if (d > worst) worst = d;
        }
    }
    if (ok == 1 && worst > 0.05f) {
        ok = 0;
        snprintf(g.err, sizeof g.err, "GPU/CPU stack mismatch: max difference %.3f", worst);
    }
    if (ok == -1) snprintf(g.err, sizeof g.err, "GPU stack self-test failed: %.180s", gpu.error());
    if (gpu_stack_free) gpu_stack_free();
done:
    *maxDiff = worst;
    free(in); free(cm); free(c2); free(gm); free(g2); free(cc); free(gc);
    return ok;
}

/* ================================================================== */
/* Step 7: plate solving                                               */
/*                                                                     */
/* The solver thread takes one image (newest live frame or the stack), */
/* finds the stars itself, writes them as an x/y list and runs          */
/* astrometry.net's solve-field on that list (no image re-reading).     */
/* A scale hint from the telescope settings keeps it fast: only the     */
/* index files whose quad sizes fit the field are searched.             */
/* ================================================================== */
#define SOLVE_MAX_STARS 300

static struct {
    pthread_t thr;
    int threadLive;
    volatile int state;             /* 0 idle, 1 running, 2 solved, 3 failed */
    volatile pid_t pid;             /* solve-field process group while running */
    volatile int cancel;
    /* job */
    int src, W, H, colourHalf, timeLimit;
    float scale, scaleTol;
    double hintRa, hintDec;
    double jd;                      /* UTC Julian date when the image was taken (camera images) */
    double wCrval[2], wCrpix[2], wCd[4];   /* last solution's TAN WCS (solved-image pixels, 1-based) */
    int wValid, wSrc, wColourHalf, wW, wH;
    double wJd;
    float hintRad;                  /* > 0: search near hintRa/hintDec first */
    float *img;
    char work[900], index[900], out[900], exe[600];
    /* result */
    double ra, dec;
    float fieldW, fieldH, rot, pixScale, secs;
    int stars;
    char msg[200];
} sv;

static int find_solve_field(char *out, size_t len)
{
    const char *path = getenv("PATH");
    const char *extra[] = { "/usr/bin", "/usr/local/bin", "/usr/local/astrometry/bin", NULL };
    char dir[400];
    int i;
    if (path) {
        const char *p = path;
        while (*p) {
            const char *e = strchr(p, ':');
            size_t n = e ? (size_t)(e - p) : strlen(p);
            if (n > 0 && n < sizeof dir) {
                memcpy(dir, p, n); dir[n] = 0;
                snprintf(out, len, "%s/solve-field", dir);
                if (access(out, X_OK) == 0) return 0;
            }
            if (!e) break;
            p = e + 1;
        }
    }
    for (i = 0; extra[i]; i++) {
        snprintf(out, len, "%s/solve-field", extra[i]);
        if (access(out, X_OK) == 0) return 0;
    }
    return -1;
}

/* big-endian float32 */
static void put_be_f32(uint8_t *b, float f)
{
    union { float f; uint32_t u; } v;
    v.f = f;
    b[0] = (uint8_t)(v.u >> 24); b[1] = (uint8_t)(v.u >> 16); b[2] = (uint8_t)(v.u >> 8); b[3] = (uint8_t)v.u;
}

/* x/y star list as a FITS binary table (X, Y, FLUX; 1-based pixel centres) */
static int write_xyls(const char *path, const Star *st, int n)
{
    char hdr[2880];
    int k = 0, i;
    FILE *fp = fopen(path, "wb");
    size_t bytes;
    uint8_t row[12];
    if (!fp) return -1;
    memset(hdr, ' ', sizeof hdr);
    card_raw(hdr, &k, "SIMPLE  =                    T");
    card_int(hdr, &k, "BITPIX", 8, "");
    card_int(hdr, &k, "NAXIS", 0, "");
    card_raw(hdr, &k, "EXTEND  =                    T");
    card_raw(hdr, &k, "END");
    fwrite(hdr, 1, 2880, fp);
    memset(hdr, ' ', sizeof hdr); k = 0;
    card_raw(hdr, &k, "XTENSION= 'BINTABLE'           / binary table");
    card_int(hdr, &k, "BITPIX", 8, "");
    card_int(hdr, &k, "NAXIS", 2, "");
    card_int(hdr, &k, "NAXIS1", 12, "bytes per row");
    card_int(hdr, &k, "NAXIS2", n, "stars");
    card_int(hdr, &k, "PCOUNT", 0, "");
    card_int(hdr, &k, "GCOUNT", 1, "");
    card_int(hdr, &k, "TFIELDS", 3, "");
    card_str(hdr, &k, "TTYPE1", "X", ""); card_str(hdr, &k, "TFORM1", "E", "");
    card_str(hdr, &k, "TTYPE2", "Y", ""); card_str(hdr, &k, "TFORM2", "E", "");
    card_str(hdr, &k, "TTYPE3", "FLUX", ""); card_str(hdr, &k, "TFORM3", "E", "");
    card_int(hdr, &k, "IMAGEW", sv.W, "");
    card_int(hdr, &k, "IMAGEH", sv.H, "");
    card_raw(hdr, &k, "END");
    fwrite(hdr, 1, 2880, fp);
    for (i = 0; i < n; i++) {
        put_be_f32(row, st[i].x + 1.0f);
        put_be_f32(row + 4, st[i].y + 1.0f);
        put_be_f32(row + 8, st[i].flux);
        fwrite(row, 1, 12, fp);
    }
    bytes = (size_t)n * 12;
    if (bytes % 2880) { static const uint8_t z[2880]; fwrite(z, 1, 2880 - bytes % 2880, fp); }
    return fclose(fp) == 0 ? 0 : -1;
}

/* read the primary header of a FITS file (the .wcs solve-field writes).
 * Tolerant: some astrometry.net versions do not pad the .wcs to 2880 bytes. */
static int read_fits_header(const char *path, char **out, int *ncards)
{
    FILE *fp = fopen(path, "rb");
    char *h;
    size_t got, i;
    const size_t cap = 2880 * 64;
    if (!fp) return -1;
    h = (char *)malloc(cap);
    if (!h) { fclose(fp); return -1; }
    got = fread(h, 1, cap, fp);
    fclose(fp);
    for (i = 0; i + 8 <= got; i += 80) {
        if (!strncmp(h + i, "END", 3) && (i + 3 >= got || h[i + 3] == ' ')) {
            *ncards = (int)(i / 80);
            *out = h;
            return 0;
        }
    }
    free(h);
    return -1;
}

static int hdr_value(const char *h, int nc, const char *key, double *v)
{
    int i;
    size_t kl = strlen(key);
    for (i = 0; i < nc; i++) {
        const char *c = h + i * 80;
        if (!strncmp(c, key, kl) && (c[kl] == ' ' || c[kl] == '=') && c[8] == '=') {
            char t[72];
            memcpy(t, c + 10, 70); t[70] = 0;
            *v = atof(t);
            return 0;
        }
    }
    return -1;
}

/* solved image: 32-bit float + the WCS cards, so other programs know where it points */
static int write_solved_fits(const char *path, const char *wcs, int nwcs)
{
    int cap = 36 * (4 + (nwcs + 20) / 36 + 1), n = 0, i;
    char *hdr = (char *)malloc((size_t)cap * 80), iso[64];
    size_t np = (size_t)sv.W * sv.H, bytes;
    uint8_t *buf;
    FILE *fp;
    if (!hdr) return -1;
    memset(hdr, ' ', (size_t)cap * 80);
    card_raw(hdr, &n, "SIMPLE  =                    T / file conforms to FITS standard");
    card_int(hdr, &n, "BITPIX", -32, "32-bit float");
    card_int(hdr, &n, "NAXIS", 2, "number of axes");
    card_int(hdr, &n, "NAXIS1", sv.W, "width");
    card_int(hdr, &n, "NAXIS2", sv.H, "height");
    ticks_to_iso(utc_ticks(), iso, sizeof iso);
    card_str(hdr, &n, "DATE", iso, "UTC file written");
    card_str(hdr, &n, "INSTRUME", g.info.Name, "camera");
    if (g.telescope[0]) card_str(hdr, &n, "TELESCOP", g.telescope, "telescope");
    if (g.focalMm > 0) card_int(hdr, &n, "FOCALLEN", g.focalMm, "focal length (mm)");
    card_str(hdr, &n, "IMAGETYP", sv.src == 1 ? "Light Stack" : "Light Frame", "solved image");
    if (sv.colourHalf) card_raw(hdr, &n, "COMMENT colour sensor: 2x2 superpixel luminance (half size)");
    card_dbl(hdr, &n, "RA", sv.ra, "field centre RA (deg, J2000)");
    card_dbl(hdr, &n, "DEC", sv.dec, "field centre Dec (deg, J2000)");
    card_str(hdr, &n, "SWCREATE", "QBCap / libqbcap + astrometry.net", "");
    for (i = 0; i < nwcs && n < cap - 2; i++) {
        const char *c = wcs + i * 80;
        if (!strncmp(c, "SIMPLE  ", 8) || !strncmp(c, "BITPIX  ", 8) || !strncmp(c, "NAXIS", 5) ||
            !strncmp(c, "EXTEND  ", 8) || !strncmp(c, "END     ", 8) || !strncmp(c, "        ", 8) ||
            !strncmp(c, "DATE    ", 8)) continue;
        memcpy(hdr + n * 80, c, 80);
        n++;
    }
    card_raw(hdr, &n, "END");
    fp = fopen(path, "wb");
    if (!fp) { free(hdr); return -1; }
    fwrite(hdr, 1, (size_t)((n + 35) / 36) * 2880, fp);
    free(hdr);
    buf = (uint8_t *)malloc((size_t)sv.W * 4);
    if (!buf) { fclose(fp); return -1; }
    for (i = 0; i < sv.H; i++) {
        int x;
        for (x = 0; x < sv.W; x++) put_be_f32(buf + 4 * x, sv.img[(size_t)i * sv.W + x]);
        fwrite(buf, 1, (size_t)sv.W * 4, fp);
    }
    free(buf);
    bytes = np * 4;
    if (bytes % 2880) { static const uint8_t z[2880]; fwrite(z, 1, 2880 - bytes % 2880, fp); }
    return fclose(fp) == 0 ? 0 : -1;
}

/* pull "Field rotation angle: up is X degrees E of N" from solve-field's output */
static int parse_rotation(const char *logPath, float *rot)
{
    FILE *fp = fopen(logPath, "r");
    char line[512];
    int found = 0;
    if (!fp) return -1;
    while (fgets(line, sizeof line, fp)) {
        char *p = strstr(line, "Field rotation angle: up is ");
        if (p) { *rot = (float)atof(p + 28); found = 1; }
    }
    fclose(fp);
    return found ? 0 : -1;
}

/* ---- index files ----------------------------------------------------
 * astrometry.net index names carry their quad scale:
 *   index-41NN.fits      NN = 07..19      (Tycho-2, wide fields)
 *   index-520N-TT.fits   N  = 0..6        (Gaia, 48 sky tiles each)
 *   index-52m1-TT.fits   scale "-1"       (smallest quads)
 * Quad size range (arcmin) for scale k:                               */
static const float quadLo[21] = { 1.4f, 2.0f, 2.8f, 4.0f, 5.6f, 8.0f, 11.0f, 16.0f, 22.0f, 30.0f, 42.0f,
                                  60.0f, 85.0f, 120.0f, 170.0f, 240.0f, 340.0f, 480.0f, 680.0f, 1000.0f, 1400.0f };
/* quadLo[k + 1] = low edge of scale k (k = -1 .. 19); high edge = quadLo[k + 2] (2000 for k = 19) */

#define MAX_INDEX 1200
static struct { char name[96]; int k; } ixList[MAX_INDEX];
static int ixCount = 0;

static int parse_index_name(const char *n)
{
    int a, b;
    if (strncmp(n, "index-", 6) != 0) return -99;
    if (strlen(n) < 11 || strcmp(n + strlen(n) - 5, ".fits") != 0) return -99;
    if (!strncmp(n + 6, "52m1", 4)) return -1;
    if (sscanf(n + 6, "%2d%2d", &a, &b) != 2) return -99;
    if ((a == 41 || a == 42) && b >= 0 && b <= 19) return b;
    if (a == 52 && b >= 0 && b <= 6) return b;
    if ((a == 50 || a == 51) && b >= 0 && b <= 7) return b;
    return -99;
}

static int scan_index_dir(const char *dir)
{
    DIR *d = opendir(dir);
    struct dirent *e;
    ixCount = 0;
    if (!d) return -1;
    while ((e = readdir(d)) && ixCount < MAX_INDEX) {
        int k = parse_index_name(e->d_name);
        if (k < -1) continue;              /* not an index file (solve.fits etc.) */
        snprintf(ixList[ixCount].name, sizeof ixList[0].name, "%s", e->d_name);
        ixList[ixCount].k = k;
        ixCount++;
    }
    closedir(d);
    return ixCount;
}

/* config with the index files whose quads suit fields fwLo..fwHi arcmin,
 * widest quads first (they are the small, fast files). Returns count. */
static int write_pass_cfg(const char *cfg, float fwLo, float fwHi)
{
    FILE *fc = fopen(cfg, "w");
    int k, i, n = 0;
    float qLo = 0.12f * fwLo, qHi = 0.80f * fwHi;
    if (!fc) return -1;
    for (k = 19; k >= -1; k--) {
        float lo = quadLo[k + 1], hi = (k == 19) ? 2000.0f : quadLo[k + 2];
        if (hi < qLo || lo > qHi) continue;
        for (i = 0; i < ixCount; i++)
            if (ixList[i].k == k) { fprintf(fc, "index %s/%s\n", sv.index, ixList[i].name); n++; }
    }
    fclose(fc);
    return n;
}

/* ---- solver star picking -------------------------------------------
 * Nebulae and galaxies fool a plain peak finder: their bright lumps
 * outrank the stars. So for solving: (1) subtract a smooth background
 * map (median of each cell, bilinear in between), (2) keep only peaks
 * whose surrounding ring is dark (stars are compact, nebula lumps are not). */
static void subtract_background(float *L, int W, int H)
{
    int cell = (W < H ? W : H) / 12;
    int gx, gy, nx, ny, x, y;
    float *grid, *tmp;
    if (cell < 12) cell = 12;
    if (cell > 64) cell = 64;
    nx = (W + cell - 1) / cell; ny = (H + cell - 1) / cell;
    grid = (float *)malloc(sizeof(float) * nx * ny);
    tmp = (float *)malloc(sizeof(float) * cell * cell);
    if (!grid || !tmp) { free(grid); free(tmp); return; }
    for (gy = 0; gy < ny; gy++)
        for (gx = 0; gx < nx; gx++) {
            int k = 0, x0 = gx * cell, y0 = gy * cell;
            for (y = y0; y < y0 + cell && y < H; y++)
                for (x = x0; x < x0 + cell && x < W; x++) tmp[k++] = L[(size_t)y * W + x];
            qsort(tmp, k, sizeof(float), cmp_float_s);
            grid[gy * nx + gx] = tmp[k / 3];        /* lower third: ignores stars in the cell */
        }
    for (y = 0; y < H; y++) {
        float fy = (y + 0.5f) / cell - 0.5f;
        int y0 = (int)floorf(fy), y1;
        float ty;
        if (y0 < 0) { y0 = 0; fy = 0; }
        y1 = y0 + 1 < ny ? y0 + 1 : y0;
        ty = fy - y0; if (ty < 0) ty = 0; if (ty > 1) ty = 1;
        for (x = 0; x < W; x++) {
            float fx = (x + 0.5f) / cell - 0.5f, tx, b;
            int x0 = (int)floorf(fx), x1;
            if (x0 < 0) { x0 = 0; fx = 0; }
            x1 = x0 + 1 < nx ? x0 + 1 : x0;
            tx = fx - x0; if (tx < 0) tx = 0; if (tx > 1) tx = 1;
            b = (grid[y0 * nx + x0] * (1 - tx) + grid[y0 * nx + x1] * tx) * (1 - ty) +
                (grid[y1 * nx + x0] * (1 - tx) + grid[y1 * nx + x1] * tx) * ty;
            L[(size_t)y * W + x] -= b;
        }
    }
    free(grid); free(tmp);
}

/* mean of the ring at radius r (r..r+1) around a point */
static float ring_mean(const float *L, int W, int H, float cx, float cy, int r)
{
    int x, y, n = 0;
    float s = 0;
    for (y = (int)cy - r - 1; y <= (int)cy + r + 1; y++)
        for (x = (int)cx - r - 1; x <= (int)cx + r + 1; x++) {
            float d;
            if (x < 0 || y < 0 || x >= W || y >= H) continue;
            d = sqrtf((x - cx) * (x - cx) + (y - cy) * (y - cy));
            if (d >= r && d < r + 1.5f) { s += L[(size_t)y * W + x]; n++; }
        }
    return n ? s / n : 0;
}

static int solver_stars(float *L, const float *orig, int W, int H, Star *out, int maxN)
{
    enum { CAND = 1500 };
    Star *c = (Star *)malloc(sizeof(Star) * CAND);
    int nc, i, n = 0, r;
    float bg, sigma;
    float omin = 1e30f;
    size_t k, np = (size_t)W * H;
    if (!c) return 0;
    for (k = 0; k < np; k += 7) if (orig[k] < omin) omin = orig[k];
    subtract_background(L, W, H);
    bg_noise(L, (size_t)W * H, &bg, &sigma);
    nc = detect_stars(L, W, H, c, CAND);
    /* ring radius grows with image size (bigger images, bigger stars) */
    r = (W > 2000 || H > 2000) ? 6 : 4;
    for (i = 0; i < nc && n < maxN; i++) {
        int px = (int)(c[i].x + 0.5f), py = (int)(c[i].y + 0.5f);
        float peak, ring;
        if (px < 0 || py < 0 || px >= W || py >= H) continue;
        {   /* skip anything next to a blank border (black strips in scanned / cropped pictures) */
            int dx, dy, blank = 0;
            for (dy = -2 * r; dy <= 2 * r && !blank; dy++)
                for (dx = -2 * r; dx <= 2 * r; dx++) {
                    int xx = px + dx, yy = py + dy;
                    if (xx < 0 || yy < 0 || xx >= W || yy >= H) continue;
                    if (orig[(size_t)yy * W + xx] <= omin) { blank = 1; break; }
                }
            if (blank) continue;
        }
        peak = L[(size_t)py * W + px] - bg;
        ring = ring_mean(L, W, H, c[i].x, c[i].y, r) - bg;
        if (ring > 3.0f * sigma) {
            /* bright surroundings: judge sharpness against the local level further out.
             * A star (even inside a nebula or with a halo) stands well above its ring;
             * a nebula lump is broad, so its ring is nearly as bright as its peak. */
            float outer = ring_mean(L, W, H, c[i].x, c[i].y, 2 * r) - bg;
            if (ring - outer > 0.5f * (peak - outer)) continue;
        }
        out[n++] = c[i];
    }
    free(c);
    return n;
}

/* fallback: the answer as solve-field prints it (RA/Dec centre, pixel scale) */
static int parse_log_result(const char *logPath)
{
    FILE *fp = fopen(logPath, "r");
    char line[512];
    int haveC = 0, haveS = 0;
    if (!fp) return -1;
    while (fgets(line, sizeof line, fp)) {
        char *p;
        double a, b;
        if ((p = strstr(line, "Field center: (RA,Dec) = (")) && sscanf(p + 26, "%lf, %lf", &a, &b) == 2) { sv.ra = a; sv.dec = b; haveC = 1; }
        if ((p = strstr(line, "pixel scale ")) && sscanf(p + 12, "%lf", &a) == 1) { sv.pixScale = (float)a; haveS = 1; }
        if ((p = strstr(line, "Field rotation angle: up is "))) sv.rot = (float)atof(p + 28);
    }
    fclose(fp);
    if (!haveC || !haveS) return -1;
    sv.fieldW = sv.pixScale * sv.W / 60.0f;
    sv.fieldH = sv.pixScale * sv.H / 60.0f;
    return 0;
}

/* one solve-field run */
typedef struct {
    pid_t pid;
    int running, ok;
    float fwLo, fwHi;           /* field width band (arcmin) */
    int usePos;
    int list;                   /* 0 = plain star list, 1 = nebula-filtered list */
    int delayed;                /* whole-sky backup: starts after 8 s */
    char out[32], cfg[1000], log[1000], wcs[1000];
} SolvePass;

static pid_t start_pass(SolvePass *ps, const char *xylsPair)
{
    char xyls[1000];
    char sW[16], sH[16], sCpu[16], sLow[32], sHigh[32], sRa[32], sDec[32], sRad[32];
    const char *argv[64];
    int a = 0;
    pid_t pid;
    snprintf(sW, sizeof sW, "%d", sv.W);
    snprintf(sH, sizeof sH, "%d", sv.H);
    snprintf(sCpu, sizeof sCpu, "%d", sv.timeLimit);
    argv[a++] = "solve-field";
    argv[a++] = "--config"; argv[a++] = ps->cfg;
    argv[a++] = "--dir"; argv[a++] = sv.work;
    argv[a++] = "--out"; argv[a++] = ps->out;
    argv[a++] = "--overwrite";
    argv[a++] = "--no-plots";
    argv[a++] = "--no-remove-lines";      /* these two skip astrometry's python helpers */
    argv[a++] = "--uniformize"; argv[a++] = "0";
    argv[a++] = "--width"; argv[a++] = sW;
    argv[a++] = "--height"; argv[a++] = sH;
    argv[a++] = "--x-column"; argv[a++] = "X";
    argv[a++] = "--y-column"; argv[a++] = "Y";
    argv[a++] = "--sort-column"; argv[a++] = "FLUX";
    argv[a++] = "--crpix-center";
    argv[a++] = "--cpulimit"; argv[a++] = sCpu;
    argv[a++] = "--new-fits"; argv[a++] = "none";
    argv[a++] = "--rdls"; argv[a++] = "none";
    argv[a++] = "--corr"; argv[a++] = "none";
    argv[a++] = "--match"; argv[a++] = "none";
    argv[a++] = "--index-xyls"; argv[a++] = "none";
    argv[a++] = "--solved"; argv[a++] = "none";
    /* field width band -> scale limits (arcsec per pixel, on the longer side) */
    {
        int longSide = sv.W > sv.H ? sv.W : sv.H;
        snprintf(sLow, sizeof sLow, "%.4f", ps->fwLo * 60.0f / longSide);
        snprintf(sHigh, sizeof sHigh, "%.4f", ps->fwHi * 60.0f / longSide);
        argv[a++] = "--scale-units"; argv[a++] = "arcsecperpix";
        argv[a++] = "--scale-low"; argv[a++] = sLow;
        argv[a++] = "--scale-high"; argv[a++] = sHigh;
    }
    if (ps->usePos) {
        snprintf(sRa, sizeof sRa, "%.6f", sv.hintRa);
        snprintf(sDec, sizeof sDec, "%.6f", sv.hintDec);
        snprintf(sRad, sizeof sRad, "%.3f", sv.hintRad);
        argv[a++] = "--ra"; argv[a++] = sRa;
        argv[a++] = "--dec"; argv[a++] = sDec;
        argv[a++] = "--radius"; argv[a++] = sRad;
    }
    snprintf(xyls, sizeof xyls, "%s/qbsolve_%c.xyls", xylsPair, ps->list ? 'f' : 'p');
    argv[a++] = xyls;
    argv[a] = NULL;
    snprintf(ps->log, sizeof ps->log, "%s/%s.log", sv.work, ps->out);
    snprintf(ps->wcs, sizeof ps->wcs, "%s/%s.wcs", sv.work, ps->out);
    remove(ps->wcs);
    pid = fork();
    if (pid == 0) {
        int fd = open(ps->log, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        setpgid(0, 0);                      /* own group: stopping it stops its engine too */
        if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); close(fd); }
        execv(sv.exe, (char *const *)argv);
        _exit(127);
    }
    if (pid > 0) setpgid(pid, pid);
    ps->pid = pid;
    ps->running = pid > 0;
    ps->ok = 0;
    return pid;
}

static void stop_pass(SolvePass *ps)
{
    int st;
    if (!ps->running) return;
    kill(-ps->pid, SIGTERM);
    waitpid(ps->pid, &st, 0);
    ps->running = 0;
}

static void *solve_thread(void *arg)
{
    Star *st = NULL;
    int n, nwcs = 0, np = 0, i, win = -1, anyRan = 0;
    char xyls[1000];
    char *wh = NULL;
    SolvePass ps[12];
    double t0 = now_sec();
    (void)arg;

    st = (Star *)malloc(sizeof(Star) * SOLVE_MAX_STARS * 2);
    if (!st) { snprintf(sv.msg, sizeof sv.msg, "out of memory"); sv.state = 3; return NULL; }
    fix_hot_pixels(sv.img, sv.W, sv.H);
    {   /* two star lists, each tried by its own runs:
         *  plain    - brightest peaks (best for ordinary star fields)
         *  filtered - background removed, nebula lumps / border junk dropped */
        Star *stF = st + SOLVE_MAX_STARS;
        float *work = (float *)malloc(sizeof(float) * (size_t)sv.W * sv.H);
        int nPlain, nf = 0;
        nPlain = detect_stars(sv.img, sv.W, sv.H, st, SOLVE_MAX_STARS);
        if (work) {
            memcpy(work, sv.img, sizeof(float) * (size_t)sv.W * sv.H);
            nf = solver_stars(work, sv.img, sv.W, sv.H, stF, SOLVE_MAX_STARS);
            free(work);
        }
        if (nf < 10) { memcpy(stF, st, sizeof(Star) * nPlain); nf = nPlain; }   /* nothing better: same list */
        n = nPlain > nf ? nPlain : nf;
        sv.stars = n;
        if (n < 10) {
            snprintf(sv.msg, sizeof sv.msg, "only %d stars found - need 10 (longer exposure / focus?)", n);
            free(st); sv.state = 3; return NULL;
        }
        snprintf(xyls, sizeof xyls, "%s/qbsolve_p.xyls", sv.work);
        if (write_xyls(xyls, st, nPlain) == 0) {
            snprintf(xyls, sizeof xyls, "%s/qbsolve_f.xyls", sv.work);
            if (write_xyls(xyls, stF, nf) != 0) xyls[0] = 0;
        } else xyls[0] = 0;
        if (!xyls[0]) {
            snprintf(sv.msg, sizeof sv.msg, "cannot write star lists in %.140s", sv.work);
            free(st); sv.state = 3; return NULL;
        }
        snprintf(xyls, sizeof xyls, "%s", sv.work);     /* start_pass adds qbsolve_p / _f */
    }
    free(st); st = NULL;

    /* plan the runs: every band is tried with both star lists */
    memset(ps, 0, sizeof ps);
    {
        int longSide = sv.W > sv.H ? sv.W : sv.H, nb = 0, b, L;
        float bandLo[6], bandHi[6];
        int bandPos[6], bandDelay[6];
        if (sv.scale > 0) {
            float fw = sv.scale * longSide / 60.0f;          /* expected field, arcmin */
            bandLo[nb] = fw * (1.0f - sv.scaleTol); bandHi[nb] = fw * (1.0f + sv.scaleTol);
            bandPos[nb] = sv.hintRad > 0; bandDelay[nb] = 0; nb++;
            if (sv.hintRad > 0) {   /* same scale, whole sky, in case the scope moved far */
                bandLo[nb] = bandLo[0]; bandHi[nb] = bandHi[0]; bandPos[nb] = 0; bandDelay[nb] = 1; nb++;
            }
        } else {
            /* blind: three field-width bands side by side */
            bandLo[nb] = 60; bandHi[nb] = 1800; bandPos[nb] = 0; bandDelay[nb] = 0; nb++;   /* 1 - 30 deg */
            bandLo[nb] = 20; bandHi[nb] = 60;   bandPos[nb] = 0; bandDelay[nb] = 0; nb++;   /* 20 - 60' */
            bandLo[nb] = 5;  bandHi[nb] = 20;   bandPos[nb] = 0; bandDelay[nb] = 0; nb++;   /* 5 - 20' */
            if (sv.hintRad > 0) {
                /* near the last position first; the whole-sky runs wait 8 s */
                for (b = 0; b < 3; b++) {
                    bandLo[nb] = bandLo[b]; bandHi[nb] = bandHi[b]; bandPos[nb] = 0; bandDelay[nb] = 1; nb++;
                    bandPos[b] = 1;
                }
            }
        }
        for (b = 0; b < nb; b++)
            for (L = 0; L < 2; L++) {
                ps[np].fwLo = bandLo[b]; ps[np].fwHi = bandHi[b];
                ps[np].usePos = bandPos[b]; ps[np].delayed = bandDelay[b]; ps[np].list = L;
                np++;
            }
    }
    for (i = 0; i < np; i++) {
        int cnt;
        snprintf(ps[i].out, sizeof ps[i].out, "qbsolve%d", i + 1);
        snprintf(ps[i].cfg, sizeof ps[i].cfg, "%s/qbsolve%d.cfg", sv.work, i + 1);
        cnt = write_pass_cfg(ps[i].cfg, ps[i].fwLo, ps[i].fwHi);
        if (cnt <= 0) continue;          /* no index files for this band */
        if (ps[i].delayed) { ps[i].running = 0; ps[i].pid = -2; continue; }
        if (start_pass(&ps[i], sv.work) > 0) anyRan++;
    }
    if (!anyRan) {
        snprintf(sv.msg, sizeof sv.msg, ixCount ? "no index files cover this image scale" : "no index-*.fits files in the index folder");
        sv.state = 3; return NULL;
    }
    snprintf(sv.msg, sizeof sv.msg, "solving %d stars (%d run%s)...", n, anyRan, anyRan > 1 ? "s" : "");

    /* wait: first success wins; clock-time limit; cancel */
    for (;;) {
        int alive = 0;
        double el = now_sec() - t0;
        for (i = 0; i < np; i++) {
            int stt;
            if (ps[i].pid == -2 && el > 8.0) {             /* delayed whole-sky run */
                if (start_pass(&ps[i], sv.work) <= 0) ps[i].pid = 0;
            }
            if (!ps[i].running) continue;
            if (waitpid(ps[i].pid, &stt, WNOHANG) == ps[i].pid) {
                ps[i].running = 0;
                if (access(ps[i].wcs, R_OK) == 0) { ps[i].ok = 1; if (win < 0) win = i; }
            } else alive++;
        }
        for (i = 0; i < np; i++) if (ps[i].pid == -2) alive++;
        sv.secs = (float)el;
        if (win >= 0 || sv.cancel || el > sv.timeLimit || !alive) break;
        usleep(50000);
    }
    for (i = 0; i < np; i++) stop_pass(&ps[i]);
    sv.secs = (float)(now_sec() - t0);

    if (sv.cancel) { snprintf(sv.msg, sizeof sv.msg, "cancelled"); sv.state = 3; return NULL; }
    if (win < 0) {
        if (sv.secs > sv.timeLimit)
            snprintf(sv.msg, sizeof sv.msg, "gave up after %.0f s (%d stars) - try the scale hint", sv.secs, n);
        else
            snprintf(sv.msg, sizeof sv.msg, "no solution (%d stars, %.0f s) - check focus / scale / index files", n, sv.secs);
        sv.state = 3; return NULL;
    }
    if (read_fits_header(ps[win].wcs, &wh, &nwcs) != 0) {
        /* could not read the .wcs: take the answer from solve-field's printout */
        if (parse_log_result(ps[win].log) != 0) {
            snprintf(sv.msg, sizeof sv.msg, "solved, but could not read %.150s", ps[win].wcs); sv.state = 3; return NULL;
        }
        sv.out[0] = 0;   /* no WCS cards to put in a solved FITS */
        snprintf(sv.msg, sizeof sv.msg, "solved in %.1f s (%d stars; read from log)", sv.secs, n);
        sv.state = 2;
        return NULL;
    }
    {
        double cd11 = 0, cd12 = 0, cd21 = 0, cd22 = 0, det;
        float rot = 0;
        hdr_value(wh, nwcs, "CRVAL1", &sv.ra);
        hdr_value(wh, nwcs, "CRVAL2", &sv.dec);
        /* keep the TAN part of the WCS for polar alignment */
        sv.wCrval[0] = sv.ra; sv.wCrval[1] = sv.dec;
        sv.wCrpix[0] = sv.W / 2.0 + 0.5; sv.wCrpix[1] = sv.H / 2.0 + 0.5;
        hdr_value(wh, nwcs, "CRPIX1", &sv.wCrpix[0]);
        hdr_value(wh, nwcs, "CRPIX2", &sv.wCrpix[1]);
        sv.wCd[0] = sv.wCd[1] = sv.wCd[2] = sv.wCd[3] = 0;
        hdr_value(wh, nwcs, "CD1_1", &sv.wCd[0]); hdr_value(wh, nwcs, "CD1_2", &sv.wCd[1]);
        hdr_value(wh, nwcs, "CD2_1", &sv.wCd[2]); hdr_value(wh, nwcs, "CD2_2", &sv.wCd[3]);
        sv.wValid = (sv.wCd[0] * sv.wCd[3] - sv.wCd[1] * sv.wCd[2]) != 0;
        sv.wSrc = sv.src; sv.wColourHalf = sv.colourHalf; sv.wW = sv.W; sv.wH = sv.H; sv.wJd = sv.jd;
        hdr_value(wh, nwcs, "CD1_1", &cd11); hdr_value(wh, nwcs, "CD1_2", &cd12);
        hdr_value(wh, nwcs, "CD2_1", &cd21); hdr_value(wh, nwcs, "CD2_2", &cd22);
        det = fabs(cd11 * cd22 - cd12 * cd21);
        sv.pixScale = (float)(sqrt(det) * 3600.0);
        sv.fieldW = sv.pixScale * sv.W / 60.0f;
        sv.fieldH = sv.pixScale * sv.H / 60.0f;
        if (parse_rotation(ps[win].log, &rot) == 0) sv.rot = rot;
        else sv.rot = (float)(atan2(cd21, cd11) * 180.0 / M_PI);
    }
    if (sv.out[0]) {
        mkdir_parents(sv.out);
        if (write_solved_fits(sv.out, wh, nwcs) != 0) sv.out[0] = 0;
    }
    free(wh);
    snprintf(sv.msg, sizeof sv.msg, "solved in %.1f s (%d stars%s)", sv.secs, n, ps[win].usePos ? ", near last position" : "");
    sv.state = 2;
    return NULL;
}

/* read a 2-D FITS image (BITPIX 8, 16, 32, -32, -64; first plane of a cube) */
static int solve_load_fits(const char *path)
{
    char *h = NULL;
    int nc = 0, bitpix, naxis, w, hgt, bpp, x;
    double v, bzero = 0, bscale = 1;
    FILE *fp;
    size_t n, i, hdrBytes;
    uint8_t *row;
    if (read_fits_header(path, &h, &nc) != 0) { snprintf(g.err, sizeof g.err, "not a FITS file: %.200s", path); return -1; }
    bitpix = (hdr_value(h, nc, "BITPIX", &v) == 0) ? (int)v : 0;
    naxis = (hdr_value(h, nc, "NAXIS", &v) == 0) ? (int)v : 0;
    w = (hdr_value(h, nc, "NAXIS1", &v) == 0) ? (int)v : 0;
    hgt = (hdr_value(h, nc, "NAXIS2", &v) == 0) ? (int)v : 0;
    hdr_value(h, nc, "BZERO", &bzero);
    hdr_value(h, nc, "BSCALE", &bscale);
    free(h);
    hdrBytes = (size_t)((nc + 1 + 35) / 36) * 2880;
    bpp = abs(bitpix) / 8;
    if (naxis < 2 || w < 16 || hgt < 16 || (bitpix != 8 && bitpix != 16 && bitpix != 32 && bitpix != -32 && bitpix != -64))
        return fail_msg("FITS file is not a 2-D image QBCap can read");
    fp = fopen(path, "rb");
    if (!fp) return fail_msg("cannot open FITS file");
    fseek(fp, (long)hdrBytes, SEEK_SET);
    sv.W = w; sv.H = hgt; sv.colourHalf = 0;
    n = (size_t)w * hgt;
    sv.img = (float *)malloc(n * sizeof(float));
    row = (uint8_t *)malloc((size_t)w * bpp);
    if (!sv.img || !row) { fclose(fp); free(row); return fail_msg("out of memory (solve)"); }
    for (i = 0; i < n; i += w) {
        if (fread(row, bpp, w, fp) != (size_t)w) { fclose(fp); free(row); return fail_msg("FITS file is cut short"); }
        for (x = 0; x < w; x++) {
            const uint8_t *b = row + (size_t)x * bpp;
            double d;
            switch (bitpix) {
                case 8:  d = b[0]; break;
                case 16: d = (int16_t)((b[0] << 8) | b[1]); break;
                case 32: d = (int32_t)((uint32_t)b[0] << 24 | (uint32_t)b[1] << 16 | (uint32_t)b[2] << 8 | b[3]); break;
                case -32: { union { uint32_t u; float f; } c; c.u = (uint32_t)b[0] << 24 | (uint32_t)b[1] << 16 | (uint32_t)b[2] << 8 | b[3]; d = c.f; break; }
                default: { union { uint64_t u; double f; } c; int k; c.u = 0; for (k = 0; k < 8; k++) c.u = c.u << 8 | b[k]; d = c.f; break; }
            }
            if (d != d) d = 0;   /* NaN */
            sv.img[i + x] = (float)(bzero + bscale * d);
        }
    }
    free(row);
    fclose(fp);
    return 0;
}

/* pixels handed over from the front end (JPEG/PNG loaded by QB64), used by src 3 */
static float *svPend = NULL;
static int svPendW = 0, svPendH = 0;

/* bgra: 32-bit pixels as QB64 stores them (B,G,R,A bytes). Luminance = R+G+B. */
int qc_solve_set_pixels(const void *bgra, int w, int h)
{
    const uint8_t *p = (const uint8_t *)bgra;
    size_t n = (size_t)w * h, i;
    if (!bgra || w < 16 || h < 16) return fail_msg("image too small");
    free(svPend);
    svPend = (float *)malloc(n * sizeof(float));
    if (!svPend) { svPendW = svPendH = 0; return fail_msg("out of memory (solve)"); }
    for (i = 0; i < n; i++) svPend[i] = (float)(p[4 * i] + p[4 * i + 1] + p[4 * i + 2]) * 64.0f;
    svPendW = w; svPendH = h;
    return 0;
}

/* build the solver's image: newest live frame (src 0), the live stack (src 1),
 * a FITS file (src 2) or pixels from qc_solve_set_pixels (src 3) */
static int pm_grab_for_solve(void);

static double utc_jd(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return 2440587.5 + (ts.tv_sec + ts.tv_nsec * 1e-9) / 86400.0;
}

static int solve_grab_image(int src, const char *file)
{
    size_t n, i;
    sv.jd = utc_jd();
    if (src == 2) return solve_load_fits(file);
    if (src == 4) return pm_grab_for_solve();
    if (src == 3) {
        if (!svPend) return fail_msg("no image loaded");
        sv.img = svPend; sv.W = svPendW; sv.H = svPendH; sv.colourHalf = 0;
        svPend = NULL; svPendW = svPendH = 0;   /* the solver owns it now */
        return 0;
    }
    if (src == 1) {
        int p;
        if (!stk.haveStack) return fail_msg("nothing stacked yet");
        sv.W = stk.W; sv.H = stk.H; sv.colourHalf = stk.colour;
        n = (size_t)sv.W * sv.H;
        sv.img = (float *)malloc(n * sizeof(float));
        if (!sv.img) return fail_msg("out of memory (solve)");
        for (i = 0; i < n; i++) {
            float v = 0;
            for (p = 0; p < stk.P; p++) v += stk.mean[p][i];
            sv.img[i] = v;
        }
        return 0;
    } else {
        uint8_t *f;
        int srcBuf, x, y, b16;
        if (!g.open || !g.buf[0]) return fail_msg("no camera open");
        f = (uint8_t *)malloc(g.frameBytes);
        if (!f) return fail_msg("out of memory (solve)");
        pthread_mutex_lock(&g.mx);
        if (g.readySeq == 0) { pthread_mutex_unlock(&g.mx); free(f); return fail_msg("no frame captured yet - start Live first"); }
        srcBuf = (g.readySeq != g.frontSeq) ? g.ready : g.front;
        memcpy(f, g.buf[srcBuf], g.frameBytes);
        pthread_mutex_unlock(&g.mx);
        b16 = g.bits16;
#define RAWPX(xx, yy) (b16 ? (float)((const uint16_t *)f)[(size_t)(yy) * g.fw + (xx)] : (float)(f[(size_t)(yy) * g.fw + (xx)] << 8))
        if (!g.info.IsColorCam) {
            sv.W = g.fw; sv.H = g.fh; sv.colourHalf = 0;
            n = (size_t)sv.W * sv.H;
            sv.img = (float *)malloc(n * sizeof(float));
            if (!sv.img) { free(f); return fail_msg("out of memory (solve)"); }
            for (y = 0; y < sv.H; y++) for (x = 0; x < sv.W; x++) sv.img[(size_t)y * sv.W + x] = RAWPX(x, y);
        } else {
            /* colour: 2x2 superpixel sum = luminance at half size (no debayer artefacts) */
            sv.W = g.fw / 2; sv.H = g.fh / 2; sv.colourHalf = 1;
            n = (size_t)sv.W * sv.H;
            sv.img = (float *)malloc(n * sizeof(float));
            if (!sv.img) { free(f); return fail_msg("out of memory (solve)"); }
            for (y = 0; y < sv.H; y++)
                for (x = 0; x < sv.W; x++)
                    sv.img[(size_t)y * sv.W + x] = RAWPX(2 * x, 2 * y) + RAWPX(2 * x + 1, 2 * y) +
                                                   RAWPX(2 * x, 2 * y + 1) + RAWPX(2 * x + 1, 2 * y + 1);
        }
#undef RAWPX
        free(f);
        /* subtract the master dark if one is loaded and matches (mono full size only) */
        pthread_mutex_lock(&calMx);
        if (!sv.colourHalf && cal.darkOn && cal.m[0].loaded && cal.m[0].w == sv.W && cal.m[0].h == sv.H)
            for (i = 0; i < n; i++) sv.img[i] -= cal.m[0].data[i];
        pthread_mutex_unlock(&calMx);
        return 0;
    }
}

void qc_solve_cancel(void);

/* src 0 = newest live frame, 1 = live stack, 2 = the FITS file named in srcFile,
 * 3 = pixels given with qc_solve_set_pixels (JPEG/PNG).
 * scale = arcsec per camera pixel (after binning) from the telescope settings; 0 = no hint.
 * workDir: scratch folder; indexDir: the index-*.fits folder; outPath: solved FITS ("" = none).
 * Returns 0 started, -1 error (qc_last_error). */
int qc_solve_start(int src, const char *srcFile, const char *workDir, const char *indexDir,
                   const char *outPath, float scale, int timeLimitSec)
{
#ifdef QC_TEST_SOLVE
    /* test build only: "solve" = read the true pointing (RA Dec, deg) from a file */
    {
        FILE *tf = fopen(getenv("QC_TEST_SOLVE") ? getenv("QC_TEST_SOLVE") : "/nonexistent", "r");
        if (tf) {
            if (fscanf(tf, "%lf %lf", &sv.ra, &sv.dec) == 2) {
                sv.fieldW = 30; sv.fieldH = 20; sv.rot = 0; sv.pixScale = 1; sv.secs = 0.1f; sv.stars = 99;
                snprintf(sv.msg, sizeof sv.msg, "test solve"); sv.out[0] = 0; sv.state = 2;
                fclose(tf); return 0;
            }
            fclose(tf);
        }
    }
#endif
    char probe[1000];
    if (sv.state == 1) return fail_msg("a solve is already running");
    if (sv.threadLive) { pthread_join(sv.thr, NULL); sv.threadLive = 0; }
    free(sv.img); sv.img = NULL;
    if (find_solve_field(sv.exe, sizeof sv.exe) != 0)
        return fail_msg("solve-field not found - install it: sudo apt install astrometry.net");
    snprintf(probe, sizeof probe, "%s", indexDir);
    if (access(probe, R_OK) != 0) { snprintf(g.err, sizeof g.err, "index folder missing: %.200s", indexDir); return -1; }
    snprintf(sv.work, sizeof sv.work, "%s", workDir);
    {   /* absolute path: solve-field runs with its own working folder */
        char *rp = realpath(indexDir, NULL);
        snprintf(sv.index, sizeof sv.index, "%s", rp ? rp : indexDir);
        free(rp);
    }
    if (scan_index_dir(sv.index) <= 0) { snprintf(g.err, sizeof g.err, "no index-*.fits files in %.200s", indexDir); return -1; }
    snprintf(sv.out, sizeof sv.out, "%s", outPath ? outPath : "");
    {   /* make sure the work folder exists */
        char t[1000];
        snprintf(t, sizeof t, "%s/x", workDir);
        mkdir_parents(t);
    }
    if (solve_grab_image(src, srcFile) != 0) { free(sv.img); sv.img = NULL; return -1; }
    sv.src = src;
    sv.scale = (scale > 0) ? scale * (sv.colourHalf ? 2.0f : 1.0f) : 0;
    sv.scaleTol = 0.25f;
    sv.timeLimit = timeLimitSec > 5 ? timeLimitSec : 60;
    sv.cancel = 0; sv.stars = 0; sv.secs = 0; sv.wValid = 0;
    sv.msg[0] = 0;
    sv.state = 1;
    if (pthread_create(&sv.thr, NULL, solve_thread, NULL)) { sv.state = 0; return fail_msg("could not start solver thread"); }
    sv.threadLive = 1;
    return 0;
}

/* search near ra/dec (degrees) first; radiusDeg <= 0 = no position hint */
int qc_solve_hint(double ra, double dec, float radiusDeg)
{
    sv.hintRa = ra; sv.hintDec = dec;
    sv.hintRad = radiusDeg > 0 ? radiusDeg : 0;
    return 0;
}

int qc_solve_status(void) { return sv.state; }

void qc_solve_cancel(void)
{
    if (sv.state != 1) return;
    sv.cancel = 1;                     /* the solver thread stops its runs within 50 ms */
}

/* ra/dec in degrees (J2000), field in arcmin, rotation in degrees (up is X deg E of N),
 * scale in arcsec per solved-image pixel. Returns state. */
int qc_solve_result(double *ra, double *dec, float *fieldW, float *fieldH, float *rot,
                    float *pixScale, float *secs, int *stars)
{
    *ra = sv.ra; *dec = sv.dec; *fieldW = sv.fieldW; *fieldH = sv.fieldH; *rot = sv.rot;
    *pixScale = sv.pixScale; *secs = (sv.state == 1) ? 0 : sv.secs; *stars = sv.stars;
    return sv.state;
}

int qc_solve_message(char *buf, int len) { copy_str(buf, len, sv.msg); return 0; }
int qc_solve_saved(char *buf, int len) { copy_str(buf, len, sv.state == 2 ? sv.out : ""); return 0; }


/* ================================================================== */
/* Step 8: polar alignment                                             */
/*                                                                     */
/* 1. solve a frame near the pole; 2. rotate the mount in RA (60-90    */
/* deg) and solve again. The two camera orientations, moved into an    */
/* Earth-fixed frame (precession to date + sidereal rotation), differ  */
/* by a rotation about the mount's RA axis: that axis, and the pixel   */
/* it passes through, fall out of the rotation matrix. 3. While the    */
/* alt/az knobs are turned (no RA motion), every new solve shows where */
/* that fixed pixel now points; its distance from the true pole of     */
/* date is the polar alignment error.                                  */
/* ================================================================== */
typedef struct { double m[3][3]; } M3;
static const double D2R = M_PI / 180.0;

static void v_norm(double v[3]) { double n = sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]); if (n > 0) { v[0] /= n; v[1] /= n; v[2] /= n; } }
static double v_dot(const double a[3], const double b[3]) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; }
static void v_cross(const double a[3], const double b[3], double o[3]) { o[0] = a[1]*b[2] - a[2]*b[1]; o[1] = a[2]*b[0] - a[0]*b[2]; o[2] = a[0]*b[1] - a[1]*b[0]; }
static void m_mulv(const M3 *a, const double v[3], double o[3]) { int i; for (i = 0; i < 3; i++) o[i] = a->m[i][0]*v[0] + a->m[i][1]*v[1] + a->m[i][2]*v[2]; }
static void m_tmulv(const M3 *a, const double v[3], double o[3]) { int i; for (i = 0; i < 3; i++) o[i] = a->m[0][i]*v[0] + a->m[1][i]*v[1] + a->m[2][i]*v[2]; }
static M3 m_mul(const M3 *a, const M3 *b) { M3 r; int i, j, k; for (i = 0; i < 3; i++) for (j = 0; j < 3; j++) { r.m[i][j] = 0; for (k = 0; k < 3; k++) r.m[i][j] += a->m[i][k] * b->m[k][j]; } return r; }
static M3 m_t(const M3 *a) { M3 r; int i, j; for (i = 0; i < 3; i++) for (j = 0; j < 3; j++) r.m[i][j] = a->m[j][i]; return r; }
/* frame rotations (coordinates of a fixed vector in a rotated frame) */
static M3 rot_z(double a) { M3 r = {{{cos(a), sin(a), 0}, {-sin(a), cos(a), 0}, {0, 0, 1}}}; return r; }
static M3 rot_y(double a) { M3 r = {{{cos(a), 0, -sin(a)}, {0, 1, 0}, {sin(a), 0, cos(a)}}}; return r; }

/* J2000 -> mean equator of date (IAU 1976) */
static M3 precess_matrix(double jd)
{
    double T = (jd - 2451545.0) / 36525.0, as = D2R / 3600.0;
    double zeta = (2306.2181 * T + 0.30188 * T * T + 0.017998 * T * T * T) * as;
    double z    = (2306.2181 * T + 1.09468 * T * T + 0.018203 * T * T * T) * as;
    double th   = (2004.3109 * T - 0.42665 * T * T - 0.041833 * T * T * T) * as;
    M3 a = rot_z(-zeta), b = rot_y(th), c = rot_z(-z), t;
    t = m_mul(&b, &a);
    return m_mul(&c, &t);
}

/* Greenwich mean sidereal angle, radians */
static double gmst_rad(double jd)
{
    double d = fmod(280.46061837 + 360.98564736629 * (jd - 2451545.0), 360.0);
    if (d < 0) d += 360.0;
    return d * D2R;
}

typedef struct { double crval[2], crpix[2], cd[4]; double jd; int colourHalf, W, H; } PaWcs;

/* TAN: pixel (1-based, solved image) -> J2000 unit vector */
static void tan_pix2vec(const PaWcs *w, double x, double y, double v[3])
{
    double dx = x - w->crpix[0], dy = y - w->crpix[1];
    double xi = (w->cd[0] * dx + w->cd[1] * dy) * D2R, eta = (w->cd[2] * dx + w->cd[3] * dy) * D2R;
    double a0 = w->crval[0] * D2R, d0 = w->crval[1] * D2R;
    double e0[3] = { cos(d0) * cos(a0), cos(d0) * sin(a0), sin(d0) };
    double ea[3] = { -sin(a0), cos(a0), 0 };
    double ed[3] = { -sin(d0) * cos(a0), -sin(d0) * sin(a0), cos(d0) };
    int i;
    for (i = 0; i < 3; i++) v[i] = e0[i] + xi * ea[i] + eta * ed[i];
    v_norm(v);
}

/* J2000 unit vector -> pixel (1-based); returns -1 if more than ~80 deg off the centre */
static int tan_vec2pix(const PaWcs *w, const double v[3], double *x, double *y)
{
    double a0 = w->crval[0] * D2R, d0 = w->crval[1] * D2R;
    double e0[3] = { cos(d0) * cos(a0), cos(d0) * sin(a0), sin(d0) };
    double ea[3] = { -sin(a0), cos(a0), 0 };
    double ed[3] = { -sin(d0) * cos(a0), -sin(d0) * sin(a0), cos(d0) };
    double d = v_dot(v, e0), xi, eta, det;
    if (d < 0.17) return -1;
    xi = v_dot(v, ea) / d / D2R; eta = v_dot(v, ed) / d / D2R;
    det = w->cd[0] * w->cd[3] - w->cd[1] * w->cd[2];
    if (det == 0) return -1;
    *x = w->crpix[0] + ( w->cd[3] * xi - w->cd[1] * eta) / det;
    *y = w->crpix[1] + (-w->cd[2] * xi + w->cd[0] * eta) / det;
    return 0;
}

/* camera orientation in the Earth-fixed equatorial frame (columns: boresight, +x, third axis) */
static M3 cam_earth_matrix(const PaWcs *w)
{
    double c0[3], c1[3], cx[3], cy[3], t;
    M3 C, P, Rz, E, tmp;
    int i;
    tan_pix2vec(w, w->crpix[0], w->crpix[1], c0);
    tan_pix2vec(w, w->crpix[0] + 50.0, w->crpix[1], c1);
    for (i = 0; i < 3; i++) cx[i] = c1[i] - c0[i];
    t = v_dot(cx, c0);
    for (i = 0; i < 3; i++) cx[i] -= t * c0[i];
    v_norm(cx);
    v_cross(c0, cx, cy);
    for (i = 0; i < 3; i++) { C.m[i][0] = c0[i]; C.m[i][1] = cx[i]; C.m[i][2] = cy[i]; }
    P = precess_matrix(w->jd);
    Rz = rot_z(gmst_rad(w->jd));
    tmp = m_mul(&P, &C);
    E = m_mul(&Rz, &tmp);
    return E;
}

static struct {
    int have1, have2;
    PaWcs w1, w2;
    double axisE[3];               /* mount RA axis, Earth-fixed frame */
    double axX, axY;               /* pixel (1-based, solved image) the axis passes through */
    double rotDeg;
    double lat, lon;               /* site, degrees (east +) */
    /* latest result */
    double errTot, errAlt, errAz;  /* arcmin; alt + = axis too high, az + = axis too far east */
    double poleX, poleY;           /* pixel of the true pole in the latest frame (1-based, solved image) */
    int poleOk;
} pa = { .lat = 31.958, .lon = -111.600 };   /* default site: Kitt Peak, AZ */

static int pa_take(PaWcs *w)
{
    if (sv.state != 2 || !sv.wValid) return fail_msg("no fresh plate solve - solve a live frame first");
    if (sv.wSrc != 0 && sv.wSrc != 4) return fail_msg("polar alignment needs a solved live frame (camera or PoleMaster), not the stack or a file");
    w->crval[0] = sv.wCrval[0]; w->crval[1] = sv.wCrval[1];
    w->crpix[0] = sv.wCrpix[0]; w->crpix[1] = sv.wCrpix[1];
    memcpy(w->cd, sv.wCd, sizeof w->cd);
    w->jd = sv.wJd; w->colourHalf = sv.wColourHalf; w->W = sv.wW; w->H = sv.wH;
    return 0;
}

/* solved-image pixel (1-based) -> camera frame pixel (0-based, full size) */
static void pa_to_frame(const PaWcs *w, double x, double y, float *fx, float *fy)
{
    double x0 = x - 1.0, y0 = y - 1.0;
    if (w->colourHalf) { x0 = 2.0 * x0 + 0.5; y0 = 2.0 * y0 + 0.5; }
    *fx = (float)x0; *fy = (float)y0;
}

int qc_pa_reset(void) { pa.have1 = pa.have2 = 0; pa.poleOk = 0; return 0; }

int qc_pa_set_site(double latDeg, double lonDeg) { pa.lat = latDeg; pa.lon = lonDeg; return 0; }

static void pa_measure(const PaWcs *w);

/* step 1 or 2: use the latest plate solve. Returns 0 ok, -1 error (qc_last_error). */
int qc_pa_capture(int step)
{
    PaWcs w;
    if (pa_take(&w) != 0) return -1;
    if (step == 1) {
        pa.w1 = w; pa.have1 = 1; pa.have2 = 0; pa.poleOk = 0;
        return 0;
    }
    if (!pa.have1) return fail_msg("do step 1 first");
    if (w.W != pa.w1.W || w.H != pa.w1.H) return fail_msg("image size changed between steps - start again");
    {
        M3 E1 = cam_earth_matrix(&pa.w1), E2 = cam_earth_matrix(&w), E1t = m_t(&E1), Q = m_mul(&E2, &E1t);
        double ax[3] = { Q.m[2][1] - Q.m[1][2], Q.m[0][2] - Q.m[2][0], Q.m[1][0] - Q.m[0][1] };
        double tr = Q.m[0][0] + Q.m[1][1] + Q.m[2][2], c = (tr - 1.0) / 2.0, vd[3], vj[3], px, py;
        M3 Rz, P;
        if (c > 1) c = 1;
        if (c < -1) c = -1;
        pa.rotDeg = acos(c) / D2R;
        if (pa.rotDeg < 15.0) {
            snprintf(g.err, sizeof g.err, "the mount only turned %.1f deg in RA - turn it 60-90 deg and try step 2 again", pa.rotDeg);
            return -1;
        }
        if (pa.rotDeg > 165.0) return fail_msg("turned too far (over 165 deg) - turn back to about 90 deg and try step 2 again");
        v_norm(ax);
        if (ax[2] < 0 && pa.lat >= 0) { ax[0] = -ax[0]; ax[1] = -ax[1]; ax[2] = -ax[2]; }
        if (ax[2] > 0 && pa.lat < 0) { ax[0] = -ax[0]; ax[1] = -ax[1]; ax[2] = -ax[2]; }
        memcpy(pa.axisE, ax, sizeof ax);
        /* where the axis meets the sky in frame 2 (camera is rigid: same pixel ever after) */
        Rz = rot_z(gmst_rad(w.jd));
        P = precess_matrix(w.jd);
        m_tmulv(&Rz, ax, vd);          /* Earth -> equator of date */
        m_tmulv(&P, vd, vj);           /* date -> J2000 */
        if (tan_vec2pix(&w, vj, &px, &py) != 0)
            return fail_msg("the mount axis is too far from this view - point closer to the pole and start again");
        pa.axX = px; pa.axY = py;
        pa.w2 = w; pa.have2 = 1;
        pa_measure(&w);
    }
    return 0;
}

/* error of the (fixed) axis pixel against the pole of date, for one solved frame */
static void pa_measure(const PaWcs *w)
{
    double vj[3], vd[3], vl[3], pole[3] = { 0, 0, pa.lat >= 0 ? 1.0 : -1.0 }, pj[3], px, py;
    M3 P = precess_matrix(w->jd), Rl = rot_z(gmst_rad(w->jd) + pa.lon * D2R);
    double s;
    tan_pix2vec(w, pa.axX, pa.axY, vj);
    m_mulv(&P, vj, vd);                 /* J2000 -> date */
    m_mulv(&Rl, vd, vl);                /* date -> local: x toward the meridian, y east, z pole */
    s = pa.lat >= 0 ? 1.0 : -1.0;
    pa.errTot = acos(fmin(1.0, fabs(vl[2]))) / D2R * 60.0;
    pa.errAlt = s * asin(vl[0]) / D2R * 60.0;      /* toward the zenith side of the pole = too high */
    pa.errAz  = asin(vl[1]) / D2R * 60.0;          /* + = too far east */
    m_tmulv(&P, pole, pj);
    pa.poleOk = tan_vec2pix(w, pj, &px, &py) == 0;
    if (pa.poleOk) { pa.poleX = px; pa.poleY = py; }
}

/* after each new live solve during adjustment: re-measure. Returns 0 ok, -1 no new solve / not ready */
int qc_pa_update(void)
{
    PaWcs w;
    if (!pa.have2) return fail_msg("finish steps 1 and 2 first");
    if (pa_take(&w) != 0) return -1;
    if (w.W != pa.w2.W || w.H != pa.w2.H) return fail_msg("image size changed - start polar alignment again");
    pa_measure(&w);
    return 0;
}

/* errors in arcmin; axis / pole as camera-frame pixels (0-based, full size).
 * Returns 0 = not ready, 1 = step 1 done, 2 = measuring (pole marker valid if *poleOk). */
int qc_pa_result(double *errTot, double *errAlt, double *errAz, double *rotDeg,
                 float *axisX, float *axisY, float *poleX, float *poleY, int *poleOk)
{
    if (!pa.have1) return 0;
    if (!pa.have2) return 1;
    *errTot = pa.errTot; *errAlt = pa.errAlt; *errAz = pa.errAz; *rotDeg = pa.rotDeg;
    pa_to_frame(&pa.w2, pa.axX, pa.axY, axisX, axisY);
    pa_to_frame(&pa.w2, pa.poleX, pa.poleY, poleX, poleY);
    *poleOk = pa.poleOk;
    return 2;
}

/* test hook: pretend a live frame was just solved with this TAN WCS at UTC Julian date jd */
int qc_pa_inject(double crval1, double crval2, double crpix1, double crpix2,
                 double cd11, double cd12, double cd21, double cd22, double jd, int w, int h)
{
    sv.wCrval[0] = crval1; sv.wCrval[1] = crval2; sv.wCrpix[0] = crpix1; sv.wCrpix[1] = crpix2;
    sv.wCd[0] = cd11; sv.wCd[1] = cd12; sv.wCd[2] = cd21; sv.wCd[3] = cd22;
    sv.wJd = jd; sv.wW = w; sv.wH = h; sv.wSrc = 0; sv.wColourHalf = 0; sv.wValid = 1;
    sv.state = 2;
    return 0;
}

/* ================================================================== */
/* Step 9: QHY PoleMaster (second camera, polar alignment only)        */
/*                                                                     */
/* libqhyccd.so is loaded at run time (dlopen) from the program folder */
/* or the system, so QBCap builds and runs without it. A small thread  */
/* takes single exposures in a loop; the newest frame is kept for the  */
/* preview and for the plate solver (solve source 4).                  */
/* ================================================================== */
typedef void qhy_handle;
static struct {
    void *lib;
    uint32_t (*Init)(void);
    uint32_t (*Release)(void);
    uint32_t (*Scan)(void);
    uint32_t (*GetId)(uint32_t, char *);
    uint32_t (*GetModel)(char *, char *);
    qhy_handle *(*Open)(char *);
    uint32_t (*Close)(qhy_handle *);
    uint32_t (*StreamMode)(qhy_handle *, uint8_t);
    uint32_t (*InitCam)(qhy_handle *);
    uint32_t (*SetParam)(qhy_handle *, int, double);
    uint32_t (*MinMax)(qhy_handle *, int, double *, double *, double *);
    uint32_t (*SetRes)(qhy_handle *, uint32_t, uint32_t, uint32_t, uint32_t);
    uint32_t (*MemLen)(qhy_handle *);
    uint32_t (*Expose)(qhy_handle *);
    uint32_t (*GetFrame)(qhy_handle *, uint32_t *, uint32_t *, uint32_t *, uint32_t *, uint8_t *);
    uint32_t (*Chip)(qhy_handle *, double *, double *, uint32_t *, uint32_t *, double *, double *, uint32_t *);
    uint32_t (*Bits)(qhy_handle *, uint32_t);
    uint32_t (*Bin)(qhy_handle *, uint32_t, uint32_t);
    uint32_t (*Cancel)(qhy_handle *);
    void (*LogLevel)(uint8_t);
    uint32_t (*IsAvail)(qhy_handle *, int);          /* optional (main QHY camera) */
    uint32_t (*Debayer)(qhy_handle *, bool);         /* optional (main QHY camera) */
    int resInit;
    /* camera */
    qhy_handle *h;
    int open;
    char name[64];
    int w, h_, bpp;
    double pixUm;
    pthread_t thr;
    int threadLive;
    volatile int quit;
    volatile int expMs, gain, settingsDirty;
    pthread_mutex_t mx;
    uint8_t *raw, *frame;        /* raw: SDK buffer; frame: newest complete (16-bit samples) */
    size_t memLen;
    volatile unsigned seq;
    unsigned shownSeq;
    double jd;
    volatile int errors;
    volatile int saturated;    /* most of the frame is at full scale */
    char err[160];
} pm = { .mx = PTHREAD_MUTEX_INITIALIZER, .expMs = 1000, .gain = 30 };

enum { QHY_GAIN = 6, QHY_OFFSET = 7, QHY_EXPOSURE = 8, QHY_TRANSFERBIT = 10, QHY_USBTRAFFIC = 12 };

static int pm_load(void)
{
    const char *names[4] = { NULL, "libqhyccd.so", "libqhyccd.so.20", NULL };
    char own[1024];
    Dl_info di;
    int i;
    if (pm.lib) return 0;
    if (dladdr((void *)pm_load, &di) && di.dli_fname) {   /* the folder libqbcap.so lives in */
        const char *slash = strrchr(di.dli_fname, '/');
        if (slash) { snprintf(own, sizeof own, "%.*s/libqhyccd.so", (int)(slash - di.dli_fname), di.dli_fname); names[0] = own; }
    }
    for (i = 0; i < 3 && !pm.lib; i++) if (names[i]) pm.lib = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
    if (!pm.lib) return fail_msg("QHY library not found - put libqhyccd.so in the QBCap folder (see install_polemaster.sh)");
#define PMSYM(f, n) if (!(*(void **)(&pm.f) = dlsym(pm.lib, n))) { snprintf(g.err, sizeof g.err, "libqhyccd.so is missing %s", n); dlclose(pm.lib); pm.lib = NULL; return -1; }
    PMSYM(Init, "InitQHYCCDResource") PMSYM(Release, "ReleaseQHYCCDResource") PMSYM(Scan, "ScanQHYCCD")
    PMSYM(GetId, "GetQHYCCDId") PMSYM(GetModel, "GetQHYCCDModel") PMSYM(Open, "OpenQHYCCD") PMSYM(Close, "CloseQHYCCD")
    PMSYM(StreamMode, "SetQHYCCDStreamMode") PMSYM(InitCam, "InitQHYCCD") PMSYM(SetParam, "SetQHYCCDParam")
    PMSYM(MinMax, "GetQHYCCDParamMinMaxStep") PMSYM(SetRes, "SetQHYCCDResolution") PMSYM(MemLen, "GetQHYCCDMemLength")
    PMSYM(Expose, "ExpQHYCCDSingleFrame") PMSYM(GetFrame, "GetQHYCCDSingleFrame") PMSYM(Chip, "GetQHYCCDChipInfo")
    PMSYM(Bits, "SetQHYCCDBitsMode") PMSYM(Bin, "SetQHYCCDBinMode") PMSYM(Cancel, "CancelQHYCCDExposingAndReadout")
#undef PMSYM
    pm.LogLevel = (void (*)(uint8_t))dlsym(pm.lib, "SetQHYCCDLogLevel");
    *(void **)(&pm.IsAvail) = dlsym(pm.lib, "IsQHYCCDControlAvailable");
    *(void **)(&pm.Debayer) = dlsym(pm.lib, "SetQHYCCDDebayerOnOff");
    if (pm.LogLevel) pm.LogLevel(2);             /* errors only - the SDK is chatty */
    return 0;
}

static void *pm_thread(void *arg)
{
    (void)arg;
    while (!pm.quit) {
        uint32_t w = 0, h = 0, bpp = 0, ch = 0, r;
        if (pm.settingsDirty) {
            pm.SetParam(pm.h, QHY_EXPOSURE, pm.expMs * 1000.0);
            pm.SetParam(pm.h, QHY_GAIN, (double)pm.gain);
            pm.settingsDirty = 0;
        }
        r = pm.Expose(pm.h);
        if (r != 0 && r != 0x2001) {      /* 0x2001 = QHYCCD_READ_DIRECTLY (fine) */
            pm.errors++; usleep(200000); continue;
        }
        if (pm.quit) break;
        r = pm.GetFrame(pm.h, &w, &h, &bpp, &ch, pm.raw);
        if (r != 0 || w == 0 || h == 0) { pm.errors++; usleep(100000); continue; }
        pthread_mutex_lock(&pm.mx);
        pm.w = (int)w; pm.h_ = (int)h; pm.bpp = (int)bpp;
        if (bpp == 16) memcpy(pm.frame, pm.raw, (size_t)w * h * 2);
        else { size_t i, n = (size_t)w * h; uint16_t *o = (uint16_t *)pm.frame; for (i = 0; i < n; i++) o[i] = (uint16_t)(pm.raw[i] << 8); }
        pm.jd = utc_jd() - pm.expMs / 2000.0 / 86400.0;     /* middle of the exposure */
        pm.seq++;
        pthread_mutex_unlock(&pm.mx);
    }
    return NULL;
}

void qc_pm_close(void);

/* find and open a QHY PoleMaster (or, if none, any single QHY camera).
 * Returns 0 ok, -1 error (qc_last_error). */
int qc_pm_open(void)
{
    uint32_t n, i, imw = 0, imh = 0, bpp = 0;
    char id[64], model[64], pick[64] = "";
    double cw, chh, pw = 0, ph;
    if (pm.open) return 0;
    if (pm_load() != 0) return -1;
    if (!pm.resInit) { if (pm.Init() != 0) return fail_msg("QHY library would not start"); pm.resInit = 1; }
    n = pm.Scan();
    if (n == 0 || n > 16) return fail_msg("no PoleMaster found on USB (plugged in? QHY firmware + rules installed?)");
    for (i = 0; i < n; i++) {
        memset(id, 0, sizeof id);
        if (pm.GetId(i, id) != 0) continue;
        if (qh.active && strcmp(id, qh.id) == 0) continue;   /* that one is the main camera */
        if (!pick[0]) snprintf(pick, sizeof pick, "%s", id);
        if (strstr(id, "POLE") || strstr(id, "Pole") || strstr(id, "pole")) { snprintf(pick, sizeof pick, "%s", id); break; }
    }
    if (!pick[0]) return fail_msg("could not read the QHY camera id");
    pm.h = pm.Open(pick);
    if (!pm.h) return fail_msg("PoleMaster found but would not open (USB permissions?)");
    pm.StreamMode(pm.h, 0);                         /* single frames */
    if (pm.InitCam(pm.h) != 0) { pm.Close(pm.h); pm.h = NULL; return fail_msg("PoleMaster would not initialise"); }
    pm.Chip(pm.h, &cw, &chh, &imw, &imh, &pw, &ph, &bpp);
    if (imw == 0 || imh == 0) { pm.Close(pm.h); pm.h = NULL; return fail_msg("PoleMaster reported no image size"); }
    pm.Bin(pm.h, 1, 1);
    pm.SetRes(pm.h, 0, 0, imw, imh);
    pm.Bits(pm.h, 8);
    pm.SetParam(pm.h, QHY_TRANSFERBIT, 8);
    pm.SetParam(pm.h, QHY_USBTRAFFIC, 30);
    pm.SetParam(pm.h, QHY_OFFSET, 10);
    pm.memLen = pm.MemLen(pm.h);
    if (pm.memLen < (size_t)imw * imh * 2) pm.memLen = (size_t)imw * imh * 2;
    pm.raw = (uint8_t *)malloc(pm.memLen);
    pm.frame = (uint8_t *)calloc((size_t)imw * imh, 2);
    if (!pm.raw || !pm.frame) { free(pm.raw); free(pm.frame); pm.raw = pm.frame = NULL; pm.Close(pm.h); pm.h = NULL; return fail_msg("out of memory (PoleMaster)"); }
    pm.w = (int)imw; pm.h_ = (int)imh; pm.pixUm = pw;
    memset(model, 0, sizeof model);
    if (pm.GetModel(pick, model) == 0 && model[0]) snprintf(pm.name, sizeof pm.name, "%s", model);
    else snprintf(pm.name, sizeof pm.name, "%.40s", pick);
    pm.seq = 0; pm.shownSeq = 0; pm.errors = 0; pm.quit = 0; pm.settingsDirty = 1;
    pm.open = 1;
    if (pthread_create(&pm.thr, NULL, pm_thread, NULL)) { qc_pm_close(); return fail_msg("could not start PoleMaster thread"); }
    pm.threadLive = 1;
    return 0;
}

void qc_pm_close(void)
{
    if (!pm.open) return;
    pm.quit = 1;
    if (pm.Cancel && pm.h) pm.Cancel(pm.h);
    if (pm.threadLive) { pthread_join(pm.thr, NULL); pm.threadLive = 0; }
    if (pm.h) pm.Close(pm.h);
    pm.h = NULL;
    free(pm.raw); free(pm.frame); pm.raw = pm.frame = NULL;
    pm.open = 0;
}

int qc_pm_is_open(void) { return pm.open; }

/* exposure in ms, gain in camera units */
int qc_pm_set(int expMs, int gain)
{
    if (expMs < 1) expMs = 1;
    if (expMs > 30000) expMs = 30000;
    pm.expMs = expMs; pm.gain = gain; pm.settingsDirty = 1;
    return 0;
}

/* name, frame size, pixel size (um x100; -1 if the view is saturated), frames taken.
 * Returns 1 if open. */
int qc_pm_info(char *name, int len, int *w, int *h, int *pixUmX100, int *frames)
{
    copy_str(name, len, pm.open ? pm.name : "");
    *w = pm.w; *h = pm.h_; *pixUmX100 = pm.saturated ? -1 : (int)(pm.pixUm * 100 + 0.5); *frames = (int)pm.seq;
    return pm.open;
}

/* draw the newest PoleMaster frame into a BGRA image (auto stretched).
 * Same geometry arguments as qc_get_preview. Returns 1 if a new frame was drawn. */
int qc_pm_preview(void *bgra, int imgW, int imgH, int dx, int dy, int dw, int dh,
                  int sx, int sy, int sw, int sh, int force)
{
    uint32_t *dst = (uint32_t *)bgra;
    static uint8_t lut[4096];
    int x, y, W, H, lo, hi;
    const uint16_t *f;
    if (!pm.open || !pm.frame || pm.seq == 0) return 0;
    if (pm.seq == pm.shownSeq && !force) return 0;
    pthread_mutex_lock(&pm.mx);
    pm.shownSeq = pm.seq;
    W = pm.w; H = pm.h_;
    f = (const uint16_t *)pm.frame;
    {   /* stretch: black at the median, white at the 99.9th percentile (12-bit histogram) */
        static int hist[4096];
        int i, n = 0, acc = 0, step;
        memset(hist, 0, sizeof hist);
        step = (W * H) / 50000 + 1;
        for (i = 0; i < W * H; i += step) { hist[f[i] >> 4]++; n++; }
        lo = 0; hi = 4095;
        for (i = 0; i < 4096; i++) { acc += hist[i]; if (acc >= n / 2) { lo = i; break; } }
        acc = 0;
        for (i = 4095; i >= 0; i--) { acc += hist[i]; if (acc >= n / 1000 + 1) { hi = i; break; } }
        /* bright or flat scene (daylight, room, saturated sensor, lens cap): the star
         * stretch would turn it all black - show it as it is instead */
        pm.saturated = (lo >= 4000);
        if (hi - lo < 64) {
            lo = 0; hi = 4095;            /* true brightness */
            for (i = 0; i < 4096; i++) {
                double t = (double)(i - lo) / (hi - lo);
                lut[i] = (uint8_t)(255.0 * (t < 0 ? 0 : t > 1 ? 1 : t));
            }
        } else {
            for (i = 0; i < 4096; i++) {
                double t = (double)(i - lo) / (hi - lo);
                if (t < 0) t = 0;
                if (t > 1) t = 1;
                lut[i] = (uint8_t)(255.0 * pow(t, 0.5));
            }
        }
    }
    if (sx < 0) sx = 0;
    if (sy < 0) sy = 0;
    if (sw <= 0 || sx + sw > W) sw = W - sx;
    if (sh <= 0 || sy + sh > H) sh = H - sy;
    if (dx < 0) dx = 0;
    if (dy < 0) dy = 0;
    if (dx + dw > imgW) dw = imgW - dx;
    if (dy + dh > imgH) dh = imgH - dy;
    for (y = 0; y < dh; y++) {
        int fy = sy + (int)((long long)y * sh / dh);
        uint32_t *row = dst + (size_t)(dy + y) * imgW + dx;
        const uint16_t *src = f + (size_t)fy * W;
        for (x = 0; x < dw; x++) {
            int fx = sx + (int)((long long)x * sw / dw);
            uint8_t v = lut[src[fx] >> 4];
            row[x] = 0xFF000000u | ((uint32_t)v << 16) | ((uint32_t)v << 8) | v;
        }
    }
    pthread_mutex_unlock(&pm.mx);
    return 1;
}

/* solver image from the newest PoleMaster frame (solve source 4) */
static int pm_grab_for_solve(void)
{
    size_t n, i;
    const uint16_t *f;
    if (!pm.open || !pm.frame || pm.seq == 0) return fail_msg("no PoleMaster frame yet");
    pthread_mutex_lock(&pm.mx);
    sv.W = pm.w; sv.H = pm.h_; sv.colourHalf = 0;
    n = (size_t)sv.W * sv.H;
    sv.img = (float *)malloc(n * sizeof(float));
    if (!sv.img) { pthread_mutex_unlock(&pm.mx); return fail_msg("out of memory (solve)"); }
    f = (const uint16_t *)pm.frame;
    for (i = 0; i < n; i++) sv.img[i] = f[i];
    sv.jd = pm.jd;
    pthread_mutex_unlock(&pm.mx);
    return 0;
}

/* ================================================================== */
/* Step 14: QHY camera as the main camera (e.g. Orion StarShoot        */
/* All-in-One = QHY5LII-C). Uses the PoleMaster's libqhyccd.so table.  */
/* No video mode: the capture thread loops expose -> read, like the G3.*/
/* ================================================================== */
enum { QHY_CAM_COLOR = 20 };
static pthread_mutex_t qh_mx = PTHREAD_MUTEX_INITIALIZER;   /* one QHY settings call at a time */

static int qh_is_polemaster(const char *id)
{
    return strcasestr(id, "pole") != NULL;
}

/* start the QHY library (shared with the PoleMaster) */
static int qh_lib(void)
{
    if (pm_load() != 0) return -1;
    if (!pm.resInit) { if (pm.Init() != 0) return fail_msg("QHY library would not start"); pm.resInit = 1; }
    return 0;
}

/* number of QHY cameras on USB that are not a PoleMaster (-1 = no QHY library).
   Also remembers the first one's id and model for qc_camera_name / qh_open. */
int qc_qhy_count(void)
{
    uint32_t n, i;
    int k = 0;
    char id[64], model[64];
    if (qh.active) return 1;          /* don't rescan USB under an open camera */
    if (qh_lib()) return -1;
    n = pm.Scan();
    if (n > 16) n = 0;
    qh.id[0] = 0;
    for (i = 0; i < n; i++) {
        memset(id, 0, sizeof id);
        if (pm.GetId(i, id) != 0 || !id[0] || qh_is_polemaster(id)) continue;
        if (!qh.id[0]) {
            snprintf(qh.id, sizeof qh.id, "%s", id);
            memset(model, 0, sizeof model);
            if (pm.GetModel(id, model) == 0 && model[0]) snprintf(qh.name, sizeof qh.name, "%s", model);
            else snprintf(qh.name, sizeof qh.name, "%.40s", id);
        }
        k++;
    }
    return k;
}

/* ---- firmware for a blank Orion All-in-One (16c0:29a0) ------------------
 * Its FX2 USB chip keeps its program in RAM, so after every power-up it waits
 * as 16c0:29a0 for someone to upload QHY5II.HEX. The udev rule normally does
 * that with fxload; if it didn't, QBCap does it here on Connect, as a normal
 * user (the rule from install_qhycam.sh makes 16c0:29a0 user-writable).
 * Upload = hold the 8051 in reset (CPUCS 0xE600 = 1), write the HEX records
 * with vendor request 0xA0, release reset (CPUCS = 0). The chip then drops
 * off the bus and comes back as 1618:0921 QHY5-II. libusb is dlopen'ed. */
#define SSAIO_VID 0x16c0
#define SSAIO_PID 0x29a0

/* 1 if a blank All-in-One (16c0:29a0) is on USB (read from sysfs, needs no permission) */
int qc_qhy_blank(void)
{
    DIR *d = opendir("/sys/bus/usb/devices");
    struct dirent *e;
    int found = 0;
    if (!d) return 0;
    while (!found && (e = readdir(d)) != NULL) {
        char p[512], t[16];
        FILE *fp;
        unsigned v = 0, pr = 0;
        if (e->d_name[0] == '.') continue;
        snprintf(p, sizeof p, "/sys/bus/usb/devices/%s/idVendor", e->d_name);
        if (!(fp = fopen(p, "r"))) continue;
        if (fgets(t, sizeof t, fp)) v = (unsigned)strtoul(t, NULL, 16);
        fclose(fp);
        if (v != SSAIO_VID) continue;
        snprintf(p, sizeof p, "/sys/bus/usb/devices/%s/idProduct", e->d_name);
        if (!(fp = fopen(p, "r"))) continue;
        if (fgets(t, sizeof t, fp)) pr = (unsigned)strtoul(t, NULL, 16);
        fclose(fp);
        if (pr == SSAIO_PID) found = 1;
    }
    closedir(d);
    return found;
}

static int hexval(const char *s, int n)
{
    int v = 0, i;
    for (i = 0; i < n; i++) {
        char c = s[i];
        v <<= 4;
        if (c >= '0' && c <= '9') v |= c - '0';
        else if (c >= 'A' && c <= 'F') v |= c - 'A' + 10;
        else if (c >= 'a' && c <= 'f') v |= c - 'a' + 10;
        else return -1;
    }
    return v;
}

/* upload QHY5II.HEX into a blank All-in-One. 0 = uploaded, -1 = error (g.err) */
static int qh_fx2_boot(void)
{
    typedef int  (*init_t)(void **);
    typedef void (*exit_t)(void *);
    typedef void *(*openvp_t)(void *, uint16_t, uint16_t);
    typedef void (*close_t)(void *);
    typedef int  (*ctrl_t)(void *, uint8_t, uint8_t, uint16_t, uint16_t, unsigned char *, uint16_t, unsigned int);
    void *lib, *ctx = NULL, *dev;
    init_t u_init; exit_t u_exit; openvp_t u_open; close_t u_close; ctrl_t u_ctrl;
    char dir[1024], path[1100], line[600];
    unsigned char one = 1, zero = 0, data[256];
    FILE *fp;
    int recs = 0, bad = 0, i;

    lib_dir(dir, sizeof dir);
    snprintf(path, sizeof path, "%sqhy/QHY5II.HEX", dir);
    fp = fopen(path, "r");
    if (!fp) fp = fopen("/lib/firmware/qhy/QHY5II.HEX", "r");
    if (!fp) return fail_msg("All-in-One needs its firmware, but qhy/QHY5II.HEX is missing from the QBCap folder");

    lib = dlopen("libusb-1.0.so.0", RTLD_NOW | RTLD_LOCAL);
    if (!lib) { fclose(fp); return fail_msg("All-in-One needs its firmware, but libusb-1.0 is not installed"); }
    *(void **)(&u_init)  = dlsym(lib, "libusb_init");
    *(void **)(&u_exit)  = dlsym(lib, "libusb_exit");
    *(void **)(&u_open)  = dlsym(lib, "libusb_open_device_with_vid_pid");
    *(void **)(&u_close) = dlsym(lib, "libusb_close");
    *(void **)(&u_ctrl)  = dlsym(lib, "libusb_control_transfer");
    if (!u_init || !u_exit || !u_open || !u_close || !u_ctrl || u_init(&ctx) != 0) {
        fclose(fp); dlclose(lib); return fail_msg("All-in-One firmware: libusb would not start");
    }
    dev = u_open(ctx, SSAIO_VID, SSAIO_PID);
    if (!dev) {
        u_exit(ctx); dlclose(lib); fclose(fp);
        return fail_msg("All-in-One found without firmware, but no USB permission - run  sh install_qhycam.sh  once (QBCap folder)");
    }

    /* 8051 into reset, write every data record, then let it run */
    if (u_ctrl(dev, 0x40, 0xA0, 0xE600, 0, &one, 1, 1000) != 1) bad = 1;
    while (!bad && fgets(line, sizeof line, fp)) {
        int len, addr, type;
        if (line[0] != ':') continue;
        len = hexval(line + 1, 2); addr = hexval(line + 3, 4); type = hexval(line + 7, 2);
        if (len < 0 || addr < 0 || type < 0) { bad = 1; break; }
        if (type == 1) break;                       /* end of file */
        if (type != 0) continue;                    /* extended address records: not used by this firmware */
        if (addr + len > 0x4000 && !(addr >= 0xE000 && addr + len <= 0xE200)) { bad = 2; break; }   /* external RAM needs a loader */
        for (i = 0; i < len; i++) {
            int b = hexval(line + 9 + i * 2, 2);
            if (b < 0) { bad = 1; break; }
            data[i] = (unsigned char)b;
        }
        if (bad) break;
        if (u_ctrl(dev, 0x40, 0xA0, (uint16_t)addr, 0, data, (uint16_t)len, 1000) != len) { bad = 3; break; }
        recs++;
    }
    fclose(fp);
    if (!bad) u_ctrl(dev, 0x40, 0xA0, 0xE600, 0, &zero, 1, 1000);   /* run (the chip disconnects now; errors here are normal) */
    u_close(dev);
    u_exit(ctx);
    dlclose(lib);
    if (bad == 2) return fail_msg("All-in-One firmware file needs a second-stage loader (not supported)");
    if (bad || recs == 0) return fail_msg("All-in-One firmware upload failed (USB error - try another port)");
    return 0;
}

/* blank All-in-One on USB: give it its firmware and wait (up to ~8 s) for it
   to come back as a QHY camera. Returns the QHY camera count afterwards. */
static int qh_boot_and_wait(void)
{
    int t, k;
    if (!qc_qhy_blank()) return 0;
    if (qh_fx2_boot()) return -1;
    for (t = 0; t < 16; t++) {
        usleep(500000);
        if (qc_qhy_blank()) continue;              /* not re-enumerated yet */
        /* the QHY library only sees new cameras after a restart of it,
           which is safe while no QHY camera (or PoleMaster) is open */
        if (!pm.open && !qh.active && pm.resInit) { pm.Release(); pm.resInit = 0; }
        k = qc_qhy_count();
        if (k > 0) return k;
    }
    return fail_msg("All-in-One firmware loaded, but the camera did not come back (unplug, plug in, try again)");
}

/* send changed exposure / gain / offset (between frames, or now when idle) */
static void qh_service(void)
{
    int d;
    if (!qh.active || !qh.h) return;
    pthread_mutex_lock(&qh_mx);
    d = __atomic_exchange_n(&qh.dirty, 0, __ATOMIC_SEQ_CST);
    if (d & 1) pm.SetParam(qh.h, QHY_EXPOSURE, (double)g.expUs);
    if (d & 2) pm.SetParam(qh.h, QHY_GAIN, (double)qh.gain);
    if (d & 4) pm.SetParam(qh.h, QHY_OFFSET, (double)qh.offset);
    pthread_mutex_unlock(&qh_mx);
}

/* open the camera (qh.id) and set it up for single frames at 'bits'.
   Used by qh_open, by a bit-depth change and by the capture thread's
   recovery - a fresh open is what reliably works on the QHY5LII.
   Call with qh_mx held. Fills qh.w/h_/pixUm/raw; returns 0 or -1. */
static int qh_setup(int bits, uint32_t *bppOut, uint32_t *colOut)
{
    uint32_t imw = 0, imh = 0, bpp = 0, col = 0;
    double cw, chh, pw = 0, ph;

    if (qh.h) { pm.Close(qh.h); qh.h = NULL; }
    qh.h = pm.Open(qh.id);
    if (!qh.h) return fail_msg("QHY camera found but would not open (USB permissions? 1618 udev rule?)");
    pm.StreamMode(qh.h, 0);                         /* single frames */
    if (pm.InitCam(qh.h) != 0) { pm.Close(qh.h); qh.h = NULL; return fail_msg("QHY camera would not initialise"); }
    pm.Chip(qh.h, &cw, &chh, &imw, &imh, &pw, &ph, &bpp);
    if (imw == 0 || imh == 0) { pm.Close(qh.h); qh.h = NULL; return fail_msg("QHY camera reported no image size"); }

    /* colour: CAM_COLOR gives the Bayer pattern (1 GB, 2 GR, 3 BG, 4 RG), otherwise mono */
    if (pm.IsAvail) col = pm.IsAvail(qh.h, QHY_CAM_COLOR);
    if (col < 1 || col > 4) col = 0;
    if (col && pm.Debayer) pm.Debayer(qh.h, false);  /* raw Bayer - QBCap debayers itself */

    pm.Bin(qh.h, 1, 1);
    pm.SetRes(qh.h, 0, 0, imw, imh);
    if (pm.Bits(qh.h, (uint32_t)bits) != 0 && bits == 16) { bits = 8; pm.Bits(qh.h, 8); }
    pm.SetParam(qh.h, QHY_TRANSFERBIT, (double)bits);
    pm.SetParam(qh.h, QHY_USBTRAFFIC, 30);
    qh.bits = bits;

    qh.memLen = pm.MemLen(qh.h);
    if (qh.memLen < (size_t)imw * imh * 2) qh.memLen = (size_t)imw * imh * 2;
    free(qh.raw);
    qh.raw = (uint8_t *)malloc(qh.memLen);
    if (!qh.raw) { pm.Close(qh.h); qh.h = NULL; return fail_msg("out of memory (QHY camera)"); }

    qh.w = (int)imw; qh.h_ = (int)imh;
    qh.pixUm = pw > 0 ? pw : 3.75;
    qh.dirty = 7;                     /* send exposure / gain / offset again */
    if (bppOut) *bppOut = bpp;
    if (colOut) *colOut = col;
    return 0;
}

static int qh_open(void)
{
    uint32_t bpp = 0, col = 0;
    double mn, mx, st;
    int k, e;

    k = qc_qhy_count();
    if (k < 0) return -1;
    if (k == 0 || !qh.id[0]) return fail_msg("no QHY camera found on USB (lsusb should show 1618:xxxx - firmware rule installed?)");
    if (pm.open && pm.name[0] && strcmp(pm.name, qh.name) == 0 && k < 2)
        return fail_msg("that QHY camera is open as the PoleMaster");

    pthread_mutex_lock(&qh_mx);
    e = qh_setup(8, &bpp, &col);
    pthread_mutex_unlock(&qh_mx);
    if (e) return e;

    /* control ranges (fallbacks if the SDK won't say) */
    qh.gainMin = 0; qh.gainMax = 100;
    if (pm.MinMax(qh.h, QHY_GAIN, &mn, &mx, &st) == 0 && mx > mn) { qh.gainMin = (int)mn; qh.gainMax = (int)mx; }
    qh.offMin = 0; qh.offMax = 255;
    if (pm.MinMax(qh.h, QHY_OFFSET, &mn, &mx, &st) == 0 && mx > mn) { qh.offMin = (int)mn; qh.offMax = (int)mx; }
    qh.expMinUs = 1; qh.expMaxUs = 600000000;
    if (pm.MinMax(qh.h, QHY_EXPOSURE, &mn, &mx, &st) == 0 && mx > mn) {
        qh.expMinUs = mn < 1 ? 1 : (int)mn;
        qh.expMaxUs = mx > 600000000.0 ? 600000000 : (int)mx;
    }

    memset(&g.info, 0, sizeof g.info);
    snprintf(g.info.Name, sizeof g.info.Name, "%s", qh.name);
    g.info.CameraID = -1;
    g.info.MaxWidth = qh.w;
    g.info.MaxHeight = qh.h_;
    g.info.IsColorCam = col ? ASI_TRUE : ASI_FALSE;
    switch (col) {
        case 1:  g.info.BayerPattern = ASI_BAYER_GB; break;
        case 2:  g.info.BayerPattern = ASI_BAYER_GR; break;
        case 3:  g.info.BayerPattern = ASI_BAYER_BG; break;
        default: g.info.BayerPattern = ASI_BAYER_RG; break;
    }
    g.info.SupportedBins[0] = 1;
    g.info.SupportedVideoFormat[0] = ASI_IMG_RAW8;
    g.info.SupportedVideoFormat[1] = ASI_IMG_RAW16;
    g.info.SupportedVideoFormat[2] = ASI_IMG_END;
    g.info.PixelSize = qh.pixUm;
    g.info.ST4Port = ASI_FALSE;      /* guiding through the QHY's ST-4 port comes later */
    g.info.IsCoolerCam = ASI_FALSE;
    g.info.BitDepth = (bpp >= 8 && bpp <= 16) ? (int)bpp : 12;
    g.id = -1;

    qh.gain = g.gainVal = qh.gainMin + (qh.gainMax - qh.gainMin) / 4;
    qh.offset = g.offsetVal = qh.offMin;
    qh.active = 1;
    g.expAuto = g.gainAuto = 0;
    g.open = 1;
    g.expUs = 10000;
    g.tempX10 = 0;
    g.tempTime = 0;
    if (!g.lut16) qc_set_stretch(0, 255, 100, 0);
    return qc_set_format(1, 0, 0, 0);
}

static void qh_close(void)
{
    pthread_mutex_lock(&qh_mx);
    if (qh.h) pm.Close(qh.h);
    qh.h = NULL;
    pthread_mutex_unlock(&qh_mx);
    free(qh.raw); qh.raw = NULL;
    qh.active = 0;
}

/* 8- or 16-bit transfer (capture is stopped by qc_set_format first).
   Changing it on an open QHY5LII leaves it sending nothing, so the camera
   is closed and opened again in the new mode (what Disconnect/Connect does).
   If the camera refuses 16-bit it stays 8-bit and QBCap says so. */
static int qh_set_bits(int bits16)
{
    int want = bits16 ? 16 : 8, e;
    if (want == qh.bits && qh.h) return 0;
    pthread_mutex_lock(&qh_mx);
    e = qh_setup(want, NULL, NULL);
    pthread_mutex_unlock(&qh_mx);
    return e;
}

/* Stop: a long exposure is cancelled so the thread can return at once.
   Short ones are left to finish - cancelling them can leave the
   QHY5LII stuck. */
static void qh_cancel(void)
{
    if (qh.h && pm.Cancel && g.expUs > 2000000) pm.Cancel(qh.h);
}

static int qh_ctrl_range(int ctl, int *mn, int *mxv, int *dflt, int *canAuto)
{
    *canAuto = 0;
    switch (ctl) {
        case ASI_GAIN:     *mn = qh.gainMin; *mxv = qh.gainMax; *dflt = qh.gainMin + (qh.gainMax - qh.gainMin) / 4; return 0;
        case ASI_OFFSET:   *mn = qh.offMin; *mxv = qh.offMax; *dflt = qh.offMin; return 0;
        case ASI_EXPOSURE: *mn = qh.expMinUs; *mxv = qh.expMaxUs; *dflt = 10000; return 0;
    }
    return -1;                       /* no such control on this QHY camera */
}

static int qh_ctrl_set(int ctl, int value)
{
    switch (ctl) {
        case ASI_EXPOSURE:
            if (value < qh.expMinUs) value = qh.expMinUs;
            if (value > qh.expMaxUs) value = qh.expMaxUs;
            g.expUs = value; g.expAuto = 0;
            __atomic_or_fetch(&qh.dirty, 1, __ATOMIC_SEQ_CST);
            break;
        case ASI_GAIN:
            if (value < qh.gainMin) value = qh.gainMin;
            if (value > qh.gainMax) value = qh.gainMax;
            qh.gain = g.gainVal = value; g.gainAuto = 0;
            __atomic_or_fetch(&qh.dirty, 2, __ATOMIC_SEQ_CST);
            break;
        case ASI_OFFSET:
            if (value < qh.offMin) value = qh.offMin;
            if (value > qh.offMax) value = qh.offMax;
            qh.offset = g.offsetVal = value;
            __atomic_or_fetch(&qh.dirty, 4, __ATOMIC_SEQ_CST);
            break;
        default:
            return 0;                /* USB bandwidth, cooler ...: nothing to do */
    }
    if (!g.run) qh_service();        /* idle: send now (running: the capture thread sends it) */
    return 0;
}

static int qh_ctrl_get(int ctl, int *value, int *autoOn)
{
    *autoOn = 0;
    switch (ctl) {
        case ASI_EXPOSURE: *value = g.expUs; return 0;
        case ASI_GAIN:     *value = qh.gain; return 0;
        case ASI_OFFSET:   *value = qh.offset; return 0;
    }
    return fail_msg("this QHY camera has no such control");
}

/* QHY capture: expose -> read, over and over */
static void *qh_cap_thread(void *arg)
{
    double t0 = now_sec();
    int n0 = 0, fails = 0;
    (void)arg;
    while (g.run) {
        uint32_t w = 0, h = 0, bpp = 0, ch = 0, r;
        size_t i, n;
        /* several bad frames in a row: open the camera again (what a
           Disconnect / Connect does by hand), then carry on */
        if (fails >= 4) {
            pthread_mutex_lock(&qh_mx);
            if (qh_setup(qh.bits, NULL, NULL) == 0)
                snprintf(g.err, sizeof g.err, "QHY: camera stopped sending - opened it again");
            pthread_mutex_unlock(&qh_mx);
            fails = 0;
            if (!qh.h) { usleep(1000000); fails = 4; continue; }
        }
        qh_service();
        r = pm.Expose(qh.h);
        if (!g.run) break;
        if (r != 0 && r != 0x2001) {      /* 0x2001 = QHYCCD_READ_DIRECTLY (fine) */
            snprintf(g.err, sizeof g.err, "QHY: exposure would not start (code %u)", r);
            fails++;
            usleep(300000);
            continue;
        }
        r = pm.GetFrame(qh.h, &w, &h, &bpp, &ch, qh.raw);
        if (!g.run) break;                /* Stop cancelled the exposure */
        if (r != 0 || w == 0 || h == 0 || (int)w != g.fw || (int)h != g.fh || ch != 1) {
            if (r != 0 || w == 0) snprintf(g.err, sizeof g.err, "QHY: frame read failed (code %u)", r);
            else snprintf(g.err, sizeof g.err, "QHY: unexpected frame %ux%u x%u (wanted %dx%d)", w, h, ch, g.fw, g.fh);
            if (now_sec() - t0 > 3.0 + g.expUs / 1e6) g.fpsX10 = 0;
            fails++;
            usleep(100000);
            continue;
        }
        fails = 0;
        n = (size_t)w * h;
        if (bpp > 8) {
            if (g.bpp == 2) memcpy(g.buf[g.back], qh.raw, n * 2);
            else { const uint16_t *s = (const uint16_t *)qh.raw; for (i = 0; i < n; i++) g.buf[g.back][i] = (uint8_t)(s[i] >> 8); }
        } else {
            if (g.bpp == 1) memcpy(g.buf[g.back], qh.raw, n);
            else { uint16_t *o = (uint16_t *)g.buf[g.back]; for (i = 0; i < n; i++) o[i] = (uint16_t)(qh.raw[i] << 8); }
        }
        cap_frame_arrived(&t0, &n0);
    }
    return NULL;
}

/* ================================================================== */
/* Step 10: mount control - Sky-Watcher / Orion SynScan motor protocol */
/*   (Russell's Atlas Pro AZ/EQ-G = AZ-EQ6, EQ mode, WiFi or USB)       */
/*   All mount I/O happens on one background thread. The GUI only sets */
/*   what it wants: a jog (must be repeated at least every 0.6 s, so a */
/*   released button or a frozen GUI stops the mount), tracking on/off,*/
/*   or stop. The thread also stops everything if an axis stalls       */
/*   (the axis encoders stop counting) or the link is lost.            */
/* ================================================================== */
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <termios.h>
#include <sys/select.h>

#define MT_SIDEREAL (360.0 / 86164.0905)
#define MT_KEEPALIVE_S 0.6
#define MT_STALL_MIN_SPEED 0.05      /* deg/s - slower moves are not stall-checked */

static const double mt_speed[7] = { 0, MT_SIDEREAL, 8 * MT_SIDEREAL, 32 * MT_SIDEREAL, 0.5, 1.0, 2.0 };

static struct {
    pthread_mutex_t mx;
    pthread_t thr;
    int open, isUdp, fd;
    volatile int quit;
    struct sockaddr_in addr;
    long cpr[3], tf[3], hs[3];
    /* wanted (set by the GUI) */
    int wantDir[3]; double wantSpeed[3], keepT[3];
    int trackOn;
    double trackRate;            /* deg/s: sidereal or lunar */
    int blocked[3];              /* after a stall: ignore a held button until it is let go */
    int gotoOn; double gotoTgt[3], gotoT0;   /* GoTo: absolute axis targets (deg) */
    /* actual (thread only, copied out under the lock) */
    int curDir[3]; double curSpeed[3];
    double startT[3], chkPos[3], chkT[3]; int bad[3];
    double pos[3]; int posOk;
    double posT; int glitch;     /* time of the last good reading; odd jumps in a row */
    double cand[3], candT;       /* the jumped reading being checked (must repeat to be believed) */
    int lost;
    char info[128], msg[160];
    int msgSeq;
} mt = { .mx = PTHREAD_MUTEX_INITIALIZER, .fd = -1 };

static double mt_now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }

static void mt_say(const char *s)
{
    pthread_mutex_lock(&mt.mx);
    snprintf(mt.msg, sizeof mt.msg, "%s", s);
    mt.msgSeq++;
    pthread_mutex_unlock(&mt.mx);
}

/* how many characters the mount sends after '=' for each command */
static int mt_reply_len(char c)
{
    switch (c) {
    case 'a': case 'b': case 'j': case 'e': return 6;
    case 'f': return 3;
    case 'g': return 2;
    default:  return 0;        /* G I J K F E: just "=" */
    }
}

/* is "in" (n chars, '\r' included or not) a believable answer to command c?
 * Right length for the command, and hex digits only. */
static int mt_reply_ok(char c, const char *in, int n)
{
    int i;
    if (n > 0 && in[n - 1] == '\r') n--;
    if (n < 1) return 0;
    if (in[0] == '!') return n == 2;                    /* "!<code>" error */
    if (in[0] != '=' || n - 1 != mt_reply_len(c)) return 0;
    for (i = 1; i < n; i++) {
        char h = in[i];
        if (!((h >= '0' && h <= '9') || (h >= 'A' && h <= 'F') || (h >= 'a' && h <= 'f'))) return 0;
    }
    return 1;
}

/* ":<c><axis><data>\r" -> reply after '=' ; 0 ok, 1 mount error, -1 no answer.
 * Over WiFi a late answer to an earlier command can turn up after a newer
 * command was sent: answers with the wrong length / not hex are thrown away
 * (same as PoleMasterQB2's pmmount.c). */
static int mt_cmd(char c, int axis, const char *data, char *reply, int len)
{
    char out[24], in[64];
    int n = 0, tries;
    snprintf(out, sizeof out, ":%c%c%s\r", c, (char)('0' + axis), data ? data : "");
    for (tries = 0; tries < (mt.isUdp ? 3 : 2); tries++) {
        if (mt.isUdp) {
            char junk[64];
            int reads;
            while (recvfrom(mt.fd, junk, sizeof junk, MSG_DONTWAIT, NULL, NULL) > 0) ;
            if (sendto(mt.fd, out, strlen(out), 0, (struct sockaddr *)&mt.addr, sizeof mt.addr) < 0) return -1;
            for (reads = 0; reads < 4; reads++) {
                n = recvfrom(mt.fd, in, sizeof in - 1, 0, NULL, NULL);
                if (n <= 0) break;                       /* timed out */
                if (mt_reply_ok(c, in, n)) break;        /* the answer to this command */
                n = 0;                                   /* a stale one - keep listening */
            }
        } else {
            int got;
            tcflush(mt.fd, TCIFLUSH);
            if (write(mt.fd, out, strlen(out)) < 0) return -1;
            n = 0;
            while (n < (int)sizeof in - 1 && (got = read(mt.fd, in + n, 1)) == 1) if (in[n++] == '\r') break;
            if (n > 0 && !mt_reply_ok(c, in, n)) n = 0;
        }
        if (n > 0 && (in[0] == '=' || in[0] == '!')) break;
        n = 0;
    }
    if (n <= 0) return -1;
    in[n] = 0;
    if (in[n - 1] == '\r') in[--n] = 0;
    if (reply && len > 0) snprintf(reply, len, "%s", in + 1);
    return in[0] == '=' ? 0 : 1;
}

static long mt_hex24(const char *s)
{
    char b[3] = { 0, 0, 0 };
    long v = 0;
    int i, n = (int)strlen(s) / 2;
    for (i = n - 1; i >= 0; i--) { b[0] = s[2 * i]; b[1] = s[2 * i + 1]; v = (v << 8) | strtol(b, NULL, 16); }
    return v;
}

static int mt_running(int a)
{
    char r[64];
    if (mt_cmd('f', a, NULL, r, sizeof r) != 0 || strlen(r) < 3) return -1;
    return (strtol((char[]){ r[1], 0 }, NULL, 16) & 1) ? 1 : 0;
}

static double mt_read_pos(int a)
{
    char r[64];
    if (mt_cmd('j', a, NULL, r, sizeof r) != 0 || strlen(r) < 6) return NAN;
    return (double)(mt_hex24(r) - 0x800000) * 360.0 / (double)mt.cpr[a];
}

static void mt_stop_axis(int a, int wait)
{
    int i;
    mt_cmd('K', a, NULL, NULL, 0);
    for (i = 0; wait && i < 60; i++) {
        if (mt_running(a) == 0) break;
        usleep(100000);
    }
    mt.curDir[a] = 0; mt.curSpeed[a] = 0;
}

/* start axis a at speed (deg/s) in dir (+1 = forward: RA west / tracking direction) */
static int mt_start_axis(int a, double speed, int dir)
{
    char data[8], r[64];
    double t1;
    long period;
    int high;
    if (speed > 2.0) speed = 2.0;
    t1 = (double)mt.tf[a] * 360.0 / speed / (double)mt.cpr[a];
    high = speed > 128.0 * MT_SIDEREAL || t1 < 10.0;
    if (high) t1 *= (double)mt.hs[a];
    period = (long)(t1 + 0.5);
    if (period < 6) period = 6;
    snprintf(data, sizeof data, "%c%c", high ? '3' : '1', dir > 0 ? '0' : '1');
    if (mt_cmd('G', a, data, r, sizeof r) != 0) return -1;
    snprintf(data, sizeof data, "%02lX%02lX%02lX", period & 0xFF, (period >> 8) & 0xFF, (period >> 16) & 0xFF);
    if (mt_cmd('I', a, data, r, sizeof r) != 0) return -1;
    if (mt_cmd('J', a, NULL, r, sizeof r) != 0) return -1;
    mt.curDir[a] = dir; mt.curSpeed[a] = speed;
    mt.startT[a] = mt_now(); mt.chkT[a] = mt.startT[a]; mt.chkPos[a] = mt.pos[a]; mt.bad[a] = 0;
    return 0;
}

static void mt_all_stop_locked_wants(void)
{
    pthread_mutex_lock(&mt.mx);
    mt.blocked[1] = mt.wantDir[1] != 0; mt.blocked[2] = mt.wantDir[2] != 0;
    mt.wantDir[1] = mt.wantDir[2] = 0; mt.trackOn = 0; mt.gotoOn = 0;
    pthread_mutex_unlock(&mt.mx);
}

/* GoTo speed profile: distance to go (deg) -> speed (deg/s); 0 = arrived */
static double mt_goto_speed(double err)
{
    err = fabs(err);
    if (err > 5.0) return 2.0;
    if (err > 2.0) return 1.0;
    if (err > 0.6) return 0.5;
    if (err > 0.15) return 32 * MT_SIDEREAL;
    if (err > 0.01) return 8 * MT_SIDEREAL;
    return 0;
}

static void *mt_thread(void *arg)
{
    double lastPosT = 0;
    (void)arg;
    while (!mt.quit) {
        double now = mt_now();
        int a, wd[3], tr;
        double ws[3], kt[3];
        pthread_mutex_lock(&mt.mx);
        for (a = 1; a <= 2; a++) {
            if (mt.wantDir[a] && now - mt.keepT[a] > MT_KEEPALIVE_S) mt.wantDir[a] = 0;   /* button released / GUI gone */
            wd[a] = mt.wantDir[a]; ws[a] = mt.wantSpeed[a]; kt[a] = mt.keepT[a];
        }
        tr = mt.trackOn;
        {
            int go = mt.gotoOn;
            double gt1 = mt.gotoTgt[1], gt2 = mt.gotoTgt[2];
            pthread_mutex_unlock(&mt.mx);
            if (go && mt.posOk && !wd[1] && !wd[2]) {
                double e1 = gt1 - mt.pos[1], e2 = gt2 - mt.pos[2];
                double s1 = mt_goto_speed(e1), s2 = mt_goto_speed(e2);
                if (s1 == 0 && s2 == 0 && mt.curDir[1] == 0 && mt.curDir[2] == 0) {
                    char m[160];
                    pthread_mutex_lock(&mt.mx); mt.gotoOn = 0; pthread_mutex_unlock(&mt.mx);
                    snprintf(m, sizeof m, "GoTo done (within %.0f arcsec).", 3600.0 * fmax(fabs(e1), fabs(e2)));
                    mt_say(m);
                } else if (now - mt.gotoT0 > 240) {
                    mt_all_stop_locked_wants();
                    mt_say("GoTo took too long - stopped.");
                } else {
                    /* drive the axes like held buttons at the profile speed */
                    wd[1] = s1 > 0 ? (e1 > 0 ? 1 : -1) : 0; ws[1] = s1;
                    wd[2] = s2 > 0 ? (e2 > 0 ? 1 : -1) : 0; ws[2] = s2;
                    tr = 0;
                }
            } else if (go && (wd[1] || wd[2])) {
                pthread_mutex_lock(&mt.mx); mt.gotoOn = 0; pthread_mutex_unlock(&mt.mx);
                mt_say("GoTo cancelled by a direction button.");
            }
        }
        (void)kt;

        /* positions every 0.25 s */
        if (now - lastPosT >= (mt.gotoOn ? 0.12 : 0.25)) {
            double p1 = mt_read_pos(1), p2 = isnan(p1) ? NAN : mt_read_pos(2);
            /* RA read a second time: over WiFi the answers can slip one command
             * behind (RA's question gets Dec's answer) - then the two RA
             * readings disagree and this poll is thrown away */
            double p1b = isnan(p2) ? NAN : mt_read_pos(1);
            int mixed = !isnan(p1b) && fabs(p1b - p1) > 0.6;   /* 2 deg/s slews move < 0.6 deg between the two */
            lastPosT = now;
            if (isnan(p1) || isnan(p2) || isnan(p1b)) {
                if (++mt.lost == 2) {
                    mt_all_stop_locked_wants();
                    mt_say("LOST CONTACT with the mount - sent STOP, tracking off. Check the mount and its WiFi.");
                    mt.curDir[1] = mt.curDir[2] = 0; mt.curSpeed[1] = mt.curSpeed[2] = 0;
                }
                /* keep sending STOP while the link is down - one STOP can be lost
                 * too, and a SynScan motor keeps turning until it hears one */
                if (mt.lost >= 2) { mt_cmd('K', 1, NULL, NULL, 0); mt_cmd('K', 2, NULL, NULL, 0); }
            } else if (mixed) {
                /* answers out of step: ignore this poll */
            } else {
                /* the axes cannot move faster than 2 deg/s: a reading that jumped
                 * further is a mixed-up answer on the WiFi link - only believed
                 * when 5 readings in a row agree WITH EACH OTHER. The gap since the
                 * last good reading is capped (after a lost link STOP was sent). */
                double gap = now - mt.posT, lim, clim;
                int jump;
                if (mt.lost >= 2) {
                    /* back in contact: make sure both motors really are stopped */
                    mt_stop_axis(1, 1); mt_stop_axis(2, 1);
                    mt_say("Mount answering again (tracking is off - turn it back on if wanted).");
                }
                mt.lost = 0;
                if (gap > 2.0) gap = 2.0;
                lim = 2.5 * gap + 0.3;
                jump = mt.posOk && (fabs(p1 - mt.pos[1]) > lim || fabs(p2 - mt.pos[2]) > lim);
                if (jump) {
                    clim = 2.5 * (now - mt.candT) + 0.3;
                    if (mt.glitch > 0 && fabs(p1 - mt.cand[1]) <= clim && fabs(p2 - mt.cand[2]) <= clim)
                        mt.glitch++;                          /* agrees with the last odd one */
                    else
                        mt.glitch = 1;                        /* a new odd reading: start counting */
                    mt.cand[1] = p1; mt.cand[2] = p2; mt.candT = now;
                }
                if (!(jump && mt.glitch < 5)) {
                    if (jump) {
                        char m[160];
                        snprintf(m, sizeof m, "Mount position jumped to RA %.1f  Dec %.1f (5 readings agree) - using it.", p1, p2);
                        mt_say(m);
                    }
                    mt.glitch = 0;
                    pthread_mutex_lock(&mt.mx);
                    mt.pos[1] = p1; mt.pos[2] = p2; mt.posOk = 1; mt.posT = now;
                    pthread_mutex_unlock(&mt.mx);
                }
            }
        }

        /* bring each axis to what is wanted */
        for (a = 1; a <= 2 && mt.lost < 2; a++) {
            int dir = 0; double sp = 0;
            if (wd[a]) { dir = wd[a]; sp = ws[a]; }
            else if (a == 1 && tr) { dir = 1; sp = mt.trackRate > 0 ? mt.trackRate : MT_SIDEREAL; }
            if (dir == mt.curDir[a] && fabs(sp - mt.curSpeed[a]) < 1e-9) continue;
            if (mt.curDir[a] != 0) mt_stop_axis(a, 1);
            if (dir != 0 && mt_start_axis(a, sp, dir) != 0) {
                mt_stop_axis(a, 0);
                mt_all_stop_locked_wants();
                mt_say("The mount refused a move command - stopped.");
            }
        }

        /* stall watchdog: the axis encoders must keep counting */
        for (a = 1; a <= 2; a++) {
            double dt, moved, want;
            if (!mt.curDir[a] || mt.curSpeed[a] < MT_STALL_MIN_SPEED || !mt.posOk) continue;
            if (mt.lost) { mt.chkT[a] = now; mt.chkPos[a] = mt.pos[a]; continue; }   /* no fresh reading: don't judge */
            dt = now - mt.chkT[a];
            if (dt < 0.5) continue;
            moved = fabs(mt.pos[a] - mt.chkPos[a]);
            want = mt.curSpeed[a] * dt;
            if (now - mt.startT[a] > 2.0 && moved < 0.25 * want) mt.bad[a]++; else mt.bad[a] = 0;
            mt.chkPos[a] = mt.pos[a]; mt.chkT[a] = now;
            if (mt.bad[a] >= 2) {
                char s[160];
                mt_stop_axis(1, 0); mt_stop_axis(2, 0);
                mt_all_stop_locked_wants();
                snprintf(s, sizeof s, "%s axis STALLED (moved %.2f deg, expected %.2f) - both axes stopped, tracking off. Check for a snag.",
                         a == 1 ? "RA" : "Dec", moved, want);
                mt_say(s);
            }
        }
        usleep(50000);
    }
    return NULL;
}

/* addr: "192.168.4.1" (WiFi, UDP 11880) or "/dev/ttyUSB0" (USB, 115200; ",9600" for EQDIR).
 * Returns 0 ok, -1 error (qc_last_error). */
int qc_mount_open(const char *addr)
{
    char r[64], dev[256];
    int a, baud = 115200;
    const char *comma;
    if (mt.open) return 0;
    memset(mt.wantDir, 0, sizeof mt.wantDir); memset(mt.blocked, 0, sizeof mt.blocked); mt.trackOn = 0; mt.lost = 0; mt.posOk = 0;
    memset(mt.curDir, 0, sizeof mt.curDir); memset(mt.curSpeed, 0, sizeof mt.curSpeed);
    if (!addr || !*addr) addr = "192.168.4.1";
    if (addr[0] == '/') {
        struct termios t;
        comma = strchr(addr, ',');
        snprintf(dev, sizeof dev, "%.*s", comma ? (int)(comma - addr) : (int)strlen(addr), addr);
        if (comma) baud = atoi(comma + 1);
        mt.fd = open(dev, O_RDWR | O_NOCTTY);
        if (mt.fd < 0) { snprintf(g.err, sizeof g.err, "mount: cannot open %.100s (%.80s)", dev, strerror(errno)); return -1; }
        tcgetattr(mt.fd, &t); cfmakeraw(&t);
        cfsetispeed(&t, baud == 9600 ? B9600 : B115200); cfsetospeed(&t, baud == 9600 ? B9600 : B115200);
        t.c_cflag |= CLOCAL | CREAD; t.c_cc[VMIN] = 0; t.c_cc[VTIME] = 5;
        tcsetattr(mt.fd, TCSANOW, &t); tcflush(mt.fd, TCIOFLUSH);
        mt.isUdp = 0;
    } else {
        struct timeval tv = { 0, 300000 };
        mt.fd = socket(AF_INET, SOCK_DGRAM, 0);
        if (mt.fd < 0) return fail_msg("mount: no socket");
        memset(&mt.addr, 0, sizeof mt.addr);
        mt.addr.sin_family = AF_INET; mt.addr.sin_port = htons(11880);
        if (inet_pton(AF_INET, addr, &mt.addr.sin_addr) != 1) { close(mt.fd); mt.fd = -1; return fail_msg("mount: bad address"); }
        setsockopt(mt.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        mt.isUdp = 1;
    }
    for (a = 1; a <= 2; a++) {
        if (mt_cmd('a', a, NULL, r, sizeof r) != 0) {
            close(mt.fd); mt.fd = -1;
            return fail_msg(mt.isUdp ? "mount: no answer - is this computer on the mount's WiFi (SynScan app closed)?"
                                     : "mount: no answer on that USB port");
        }
        mt.cpr[a] = mt_hex24(r);
        mt.tf[a] = (mt_cmd('b', a, NULL, r, sizeof r) == 0) ? mt_hex24(r) : 0;
        mt.hs[a] = 16;
        if (mt_cmd('g', a, NULL, r, sizeof r) == 0 && mt_hex24(r) > 0) mt.hs[a] = mt_hex24(r);
        if (mt.cpr[a] <= 0 || mt.tf[a] <= 0) { close(mt.fd); mt.fd = -1; return fail_msg("mount: odd answers - not moving anything"); }
    }
    snprintf(mt.info, sizeof mt.info, "Sky-Watcher motor board");
    if (mt_cmd('e', 1, NULL, r, sizeof r) == 0 && strlen(r) >= 6) {
        long v = strtol(r, NULL, 16);
        int code = (int)(v & 0xFF);
        const char *name = code == 0x05 ? "AZ-EQ6" : code == 0x00 ? "EQ6" : code == 0x01 ? "HEQ5" : code == 0x02 ? "EQ5"
                         : code == 0x03 ? "EQ3" : code == 0x04 ? "EQ8" : code == 0x06 ? "EQ8-R" : code == 0x23 ? "EQ6-R" : "mount";
        snprintf(mt.info, sizeof mt.info, "%s  firmware %ld.%02ld", name, (v >> 16) & 0xFF, (v >> 8) & 0xFF);
    }
    mt_cmd('F', 1, NULL, NULL, 0);
    mt_cmd('F', 2, NULL, NULL, 0);
    mt_cmd('K', 1, NULL, NULL, 0);
    mt_cmd('K', 2, NULL, NULL, 0);
    mt.pos[1] = mt_read_pos(1); mt.pos[2] = mt_read_pos(2);
    mt.posOk = !isnan(mt.pos[1]) && !isnan(mt.pos[2]);
    mt.quit = 0;
    if (pthread_create(&mt.thr, NULL, mt_thread, NULL) != 0) { close(mt.fd); mt.fd = -1; return fail_msg("mount: no thread"); }
    mt.open = 1;
    mt.msg[0] = 0;
    return 0;
}

void qc_mount_close(void)
{
    if (!mt.open) return;
    mt_all_stop_locked_wants();
    usleep(150000);                      /* let the thread see it */
    mt.quit = 1;
    pthread_join(mt.thr, NULL);
    mt_cmd('K', 1, NULL, NULL, 0);
    mt_cmd('K', 2, NULL, NULL, 0);
    close(mt.fd); mt.fd = -1;
    mt.open = 0;
}

int qc_mount_is_open(void) { return mt.open; }

/* jog: axis 1 = RA, 2 = Dec; speedIdx 1..6 (1x, 8x, 32x sidereal, 0.5, 1, 2 deg/s);
 * dir +1 / -1 (RA +1 = west), 0 = release. Call it every frame while the button is
 * held - the move stops 0.6 s after the last call. */
int qc_mount_move(int axis, int speedIdx, int dir)
{
    if (!mt.open || axis < 1 || axis > 2) return -1;
    if (speedIdx < 1) speedIdx = 1;
    if (speedIdx > 6) speedIdx = 6;
    pthread_mutex_lock(&mt.mx);
    {
        double now = mt_now();
        /* a stop (stall / lost link / Stop) cancels the held button: it has to be let go first */
        if (mt.blocked[axis] && (dir == 0 || now - mt.keepT[axis] > MT_KEEPALIVE_S)) mt.blocked[axis] = 0;
        mt.keepT[axis] = now;
        if (mt.blocked[axis]) { pthread_mutex_unlock(&mt.mx); return 1; }
        mt.wantDir[axis] = dir > 0 ? 1 : dir < 0 ? -1 : 0;
        mt.wantSpeed[axis] = mt_speed[speedIdx];
    }
    pthread_mutex_unlock(&mt.mx);
    return 0;
}

int qc_mount_track(int onFlag)
{
    if (!mt.open) return -1;
    pthread_mutex_lock(&mt.mx);
    mt.trackOn = onFlag ? 1 : 0;
    pthread_mutex_unlock(&mt.mx);
    return 0;
}

/* 0 = sidereal, 1 = lunar (14.685 arcsec/s) */
int qc_mount_track_rate(int lunar)
{
    pthread_mutex_lock(&mt.mx);
    mt.trackRate = lunar ? 14.685 / 3600.0 : MT_SIDEREAL;
    pthread_mutex_unlock(&mt.mx);
    return 0;
}

int qc_mount_stop(void)
{
    if (!mt.open) return -1;
    mt_all_stop_locked_wants();
    return 0;
}

/* returns 1 = connected, 0 = not open, -1 = no answer from the mount.
 * axis angles in degrees (counted from where the mount was at power-up);
 * state: 0 stopped, 1 moving, 2 tracking. */
int qc_mount_status(double *raDeg, double *decDeg, int *raState, int *decState, int *tracking)
{
    if (!mt.open) return 0;
    pthread_mutex_lock(&mt.mx);
    if (raDeg) *raDeg = mt.pos[1];
    if (decDeg) *decDeg = mt.pos[2];
    if (raState) *raState = mt.gotoOn ? 3 : mt.curDir[1] == 0 ? 0 : (mt.wantDir[1] == 0 && mt.trackOn && mt.curSpeed[1] < 1.5 * MT_SIDEREAL) ? 2 : 1;
    if (decState) *decState = mt.gotoOn ? 3 : mt.curDir[2] ? 1 : 0;
    if (tracking) *tracking = mt.trackOn;
    pthread_mutex_unlock(&mt.mx);
    return mt.lost >= 2 ? -1 : 1;
}

/* newest notable message (stall, lost link...). Returns its sequence number. */
int qc_mount_message(char *buf, int len)
{
    int s;
    pthread_mutex_lock(&mt.mx);
    copy_str(buf, len, mt.msg);
    s = mt.msgSeq;
    pthread_mutex_unlock(&mt.mx);
    return s;
}

int qc_mount_info(char *buf, int len) { copy_str(buf, len, mt.open ? mt.info : ""); return mt.open ? 0 : -1; }

/* GoTo by axis amounts (degrees, + = the same way as the West / Dec + buttons).
 * The thread drives both axes, slowing down near the end, and stops within ~0.01 deg.
 * A direction button, STOP, a stall or a lost link cancels it. Tracking (if on)
 * carries on when it is done. Refuses moves over 180 deg. */
int qc_mount_goto_axes(double dRA, double dDec)
{
    if (!mt.open) return fail_msg("mount not connected");
    if (fabs(dRA) > 180 || fabs(dDec) > 180) return fail_msg("GoTo move too large");
    if (!mt.posOk) return fail_msg("no mount position yet");
    pthread_mutex_lock(&mt.mx);
    mt.gotoTgt[1] = mt.pos[1] + dRA;
    mt.gotoTgt[2] = mt.pos[2] + dDec;
    mt.gotoT0 = mt_now();
    mt.wantDir[1] = mt.wantDir[2] = 0;
    mt.gotoOn = 1;
    pthread_mutex_unlock(&mt.mx);
    return 0;
}

/* local sidereal time in degrees for a longitude (east +) - from the computer clock (UTC) */
double qc_mount_lst(double lonDeg)
{
    double d = gmst_rad(utc_jd()) / D2R + lonDeg;
    d = fmod(d, 360.0);
    if (d < 0) d += 360.0;
    return d;
}

/* ------------------------------------------------------------------ */
/* The Moon (for GoTo): Meeus ch. 47, main terms (~10-20 arcsec),      */
/* topocentric for the site, returned as J2000 RA/Dec like the list.   */
/* ------------------------------------------------------------------ */
static const signed char moon_lr_arg[][4] = {
    {0,0,1,0},{2,0,-1,0},{2,0,0,0},{0,0,2,0},{0,1,0,0},{0,0,0,2},{2,0,-2,0},{2,-1,-1,0},
    {2,0,1,0},{2,-1,0,0},{0,1,-1,0},{1,0,0,0},{0,1,1,0},{2,0,0,-2},{0,0,1,2},{0,0,1,-2},
    {4,0,-1,0},{0,0,3,0},{4,0,-2,0},{2,1,-1,0},{2,1,0,0},{1,0,-1,0},{1,1,0,0},{2,-1,1,0},
    {2,0,2,0},{4,0,0,0},{2,0,-3,0},{0,1,-2,0},{2,0,-1,2},{2,-1,-2,0},{1,0,1,0},{2,-2,0,0} };
static const int moon_l[] = { 6288774,1274027,658314,213618,-185116,-114332,58793,57066,
    53322,45758,-40923,-34720,-30383,15327,-12528,10980,10675,10034,8548,-7888,-6766,-5163,4987,4036,
    3994,3861,3665,-2689,-2602,2390,-2348,2236 };
static const int moon_r[] = { -20905355,-3699111,-2955968,-569925,48888,-3149,246158,-152138,
    -170733,-204586,-129620,108743,104755,10321,0,79661,-34782,-23210,-21636,24208,30824,-8379,-16675,-12831,
    -10445,-11650,14403,-7003,0,10056,6322,-9884 };
static const signed char moon_b_arg[][4] = {
    {0,0,0,1},{0,0,1,1},{0,0,1,-1},{2,0,0,-1},{2,0,-1,1},{2,0,-1,-1},{2,0,0,1},{0,0,2,1},{2,0,1,-1},{0,0,2,-1},
    {2,-1,0,-1},{2,0,-2,-1},{2,0,1,1},{2,1,0,-1},{2,-1,-1,1},{2,-1,0,1},{2,-1,-1,-1},{0,1,-1,-1},{4,0,-1,-1},{0,1,0,1} };
static const int moon_b[] = { 5128122,280602,277693,173237,55413,46271,32573,17198,9266,8822,
    8216,4324,4200,-3359,2463,2211,2065,-1870,1828,-1794 };

/* J2000 RA/Dec (degrees) of the Moon seen from the site, now */
int qc_moon_radec(double latDeg, double lonDeg, double *raDeg, double *decDeg)
{
    double jd = utc_jd(), T = (jd + 69.0 / 86400.0 - 2451545.0) / 36525.0;   /* ~TT */
    double Lp = 218.3164477 + 481267.88123421 * T, D = 297.8501921 + 445267.1114034 * T;
    double M = 357.5291092 + 35999.0502909 * T, Mp = 134.9633964 + 477198.8675055 * T;
    double F = 93.2720950 + 483202.0175233 * T, E = 1 - 0.002516 * T;
    double A1 = 119.75 + 131.849 * T, A2 = 53.09 + 479264.290 * T, A3 = 313.45 + 481266.484 * T;
    double sl = 0, sr = 0, sb = 0, lam, bet, dist, eps, v[3], o[3], gst, w[3];
    M3 P, Pt;
    int i, k;
    for (i = 0; i < (int)(sizeof moon_l / sizeof moon_l[0]); i++) {
        const signed char *a = moon_lr_arg[i];
        double arg = (a[0] * D + a[1] * M + a[2] * Mp + a[3] * F) * D2R, e = 1;
        for (k = 0; k < abs(a[1]); k++) e *= E;
        sl += e * moon_l[i] * sin(arg);
        sr += e * moon_r[i] * cos(arg);
    }
    for (i = 0; i < (int)(sizeof moon_b / sizeof moon_b[0]); i++) {
        const signed char *a = moon_b_arg[i];
        double arg = (a[0] * D + a[1] * M + a[2] * Mp + a[3] * F) * D2R, e = 1;
        for (k = 0; k < abs(a[1]); k++) e *= E;
        sb += e * moon_b[i] * sin(arg);
    }
    sl += 3958 * sin(A1 * D2R) + 1962 * sin((Lp - F) * D2R) + 318 * sin(A2 * D2R);
    sb += -2235 * sin(Lp * D2R) + 382 * sin(A3 * D2R) + 175 * sin((A1 - F) * D2R) + 175 * sin((A1 + F) * D2R)
          + 127 * sin((Lp - Mp) * D2R) - 115 * sin((Lp + Mp) * D2R);
    lam = (Lp + sl / 1e6) * D2R; bet = (sb / 1e6) * D2R;
    dist = 385000.56 + sr / 1000.0;                       /* km */
    eps = (23.4392911 - 0.0130042 * T) * D2R;
    /* geocentric equatorial (of date) vector, km */
    v[0] = dist * cos(bet) * cos(lam);
    v[1] = dist * (cos(bet) * sin(lam) * cos(eps) - sin(bet) * sin(eps));
    v[2] = dist * (cos(bet) * sin(lam) * sin(eps) + sin(bet) * cos(eps));
    /* minus the observer (Earth radius, spherical Earth is close enough) */
    gst = gmst_rad(jd) + lonDeg * D2R;
    o[0] = 6378.14 * cos(latDeg * D2R) * cos(gst);
    o[1] = 6378.14 * cos(latDeg * D2R) * sin(gst);
    o[2] = 6378.14 * sin(latDeg * D2R);
    for (i = 0; i < 3; i++) v[i] -= o[i];
    /* of date -> J2000 */
    P = precess_matrix(jd); Pt = m_t(&P);
    for (i = 0; i < 3; i++) w[i] = Pt.m[i][0] * v[0] + Pt.m[i][1] * v[1] + Pt.m[i][2] * v[2];
    *raDeg = atan2(w[1], w[0]) / D2R; if (*raDeg < 0) *raDeg += 360.0;
    *decDeg = asin(w[2] / sqrt(w[0] * w[0] + w[1] * w[1] + w[2] * w[2])) / D2R;
    return 0;
}


/* ================================================================== */
/* Step 11: autoguiding (ST-4 port of the guide camera)                */
/*   Runs on the capture thread of the QBCap copy that has the guide   */
/*   camera open (QBCap --guide). Star: brightest unsaturated peak (or */
/*   near a clicked point), centroid in a small box. Calibration:      */
/*   West / East / North / South pulses measure how the star moves.    */
/*   Guiding: solve the drift into West and North pulse times, scale   */
/*   by aggressiveness, skip tiny moves, one correction then one       */
/*   settle frame (frames stream continuously in video mode).          */
/* ================================================================== */
#define GD_HIST 300
enum { GD_IDLE = 0, GD_CAL = 1, GD_GUIDE = 2 };

static struct {
    pthread_mutex_t mx;
    pthread_t pthr; int pthrLive; volatile int pquit;
    int state, paused;
    /* star */
    int have, lost; double x, y, snr, peak, bg, noise; int selX, selY;
    double lockX, lockY;
    /* calibration */
    int calPhase, calSteps, calStepsDone, calMs, calDist, calMax; double c0x, c0y;
    double vW[2], vN[2]; int calOk; double calAngle, calOrtho;
    /* guide settings */
    double aggRA, aggDec, minMove, maxPulse;
    /* pulses: 0 N, 1 S, 2 E, 3 W */
    double pulseEnd[4]; int pulseOn[4]; int skip;
    double quietUntil;      /* no measuring before this: pulse end + one full exposure + mount settle */
    /* results */
    double eRA, eDec; double hRA[GD_HIST], hDec[GD_HIST]; int hN, hPos; long frames;
    int lastRAms, lastDecms;
    int settled, settleCnt; double settlePx;
    char msg[200]; int msgSeq;
} gd = { .mx = PTHREAD_MUTEX_INITIALIZER, .selX = -1, .selY = -1, .calMs = 750, .calDist = 20, .calMax = 30,
         .aggRA = 0.7, .aggDec = 0.7, .minMove = 0.15, .maxPulse = 2000, .settlePx = 1.5 };

/* time the mount needs to finish moving after a pulse before the star is measured again */
#define GD_SETTLE_SEC 0.3

static void gd_log_note(const char *s);
static void gd_say(const char *s) { snprintf(gd.msg, sizeof gd.msg, "%s", s); gd.msgSeq++; gd_log_note(s); }

/* ---- pulses: ASIPulseGuideOn now, a small thread switches them off on time ---- */
static void *gd_pulse_thread(void *arg)
{
    (void)arg;
    while (!gd.pquit) {
        double t = now_sec();
        int d;
        for (d = 0; d < 4; d++)
            if (gd.pulseOn[d] && t >= gd.pulseEnd[d]) { ASIPulseGuideOff(g.id, (ASI_GUIDE_DIRECTION)d); gd.pulseOn[d] = 0; }
        usleep(2000);
    }
    for (int d = 0; d < 4; d++) if (gd.pulseOn[d]) { ASIPulseGuideOff(g.id, (ASI_GUIDE_DIRECTION)d); gd.pulseOn[d] = 0; }
    return NULL;
}

static void gd_pulse(int dir, int ms)
{
    int opp = dir ^ 1;                    /* N<->S, E<->W */
    if (ms <= 0) return;
    if (gd.pulseOn[opp]) { ASIPulseGuideOff(g.id, (ASI_GUIDE_DIRECTION)opp); gd.pulseOn[opp] = 0; }
    gd.pulseEnd[dir] = now_sec() + ms / 1000.0;
    /* the next frame that counts must be exposed wholly after the move has finished,
       otherwise a half-moved star is corrected again and the guider overshoots */
    {
        double q = gd.pulseEnd[dir] + g.expUs / 1e6 + GD_SETTLE_SEC;
        if (q > gd.quietUntil) gd.quietUntil = q;
    }
    if (!gd.pulseOn[dir]) { ASIPulseGuideOn(g.id, (ASI_GUIDE_DIRECTION)dir); gd.pulseOn[dir] = 1; }
}

static int gd_busy(void) { return gd.pulseOn[0] || gd.pulseOn[1] || gd.pulseOn[2] || gd.pulseOn[3]; }

/* ---- star finding ---- */
static inline double gd_px(const uint8_t *f, int x, int y)
{
    return g.bits16 ? ((const uint16_t *)f)[(size_t)y * g.fw + x] : f[(size_t)y * g.fw + x] * 256.0;
}

static int cmp_dbl(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }

/* background + noise from a sample of the area */
static void gd_bg(const uint8_t *f, int x0, int y0, int x1, int y1, double *bg, double *noise)
{
    static __thread double smp[4096];
    int n = 0, x, y, sx, sy;
    long area = (long)(x1 - x0) * (y1 - y0);
    int step = (int)sqrt((double)area / 3000.0); if (step < 1) step = 1;
    for (y = y0; y < y1; y += step) for (x = x0; x < x1 && n < 4096; x += step) smp[n++] = gd_px(f, x, y);
    if (n < 5) { *bg = 0; *noise = 1; return; }
    qsort(smp, n, sizeof(double), cmp_dbl);
    *bg = smp[n / 2];
    for (sx = 0; sx < n; sx++) smp[sx] = fabs(smp[sx] - *bg);
    qsort(smp, n, sizeof(double), cmp_dbl);
    *noise = smp[n / 2] * 1.4826; if (*noise < (g.bits16 ? 1 : 128)) *noise = g.bits16 ? 1 : 128;   /* 8-bit: steps of 256 */
    (void)sy;
}

/* best star (3x3 sum, not saturated) in the area; returns 1 if found */
static int gd_find(const uint8_t *f, int x0, int y0, int x1, int y1, double *ox, double *oy)
{
    double bg, nz, best = 0, sat = 65535 * 0.92;
    int x, y, bx = -1, by = -1, m = 12;
    if (x0 < m) x0 = m;
    if (y0 < m) y0 = m;
    if (x1 > g.fw - m) x1 = g.fw - m;
    if (y1 > g.fh - m) y1 = g.fh - m;
    if (x1 <= x0 || y1 <= y0) return 0;
    gd_bg(f, x0, y0, x1, y1, &bg, &nz);
    for (y = y0; y < y1; y++) for (x = x0; x < x1; x++) {
        double v = gd_px(f, x, y), s;
        if (v < bg + 8 * nz) continue;
        if (v < gd_px(f, x - 1, y) || v < gd_px(f, x + 1, y) || v < gd_px(f, x, y - 1) || v < gd_px(f, x, y + 1)) continue;
        if (v >= sat) continue;                                   /* saturated star: centroid is poor */
        s = v + gd_px(f, x - 1, y) + gd_px(f, x + 1, y) + gd_px(f, x, y - 1) + gd_px(f, x, y + 1) - 5 * bg;
        if (gd_px(f, x - 1, y) < bg + 2 * nz && gd_px(f, x + 1, y) < bg + 2 * nz) continue;   /* hot pixel */
        if (s > best) { best = s; bx = x; by = y; }
    }
    if (bx < 0) return 0;
    *ox = bx; *oy = by;
    return 1;
}

/* centroid in a box around (cx, cy): returns 1 if a star is there */
static int gd_centroid(const uint8_t *f, double cx, double cy, int r, double *ox, double *oy, double *snr, double *peak)
{
    int it, x, y, x0, y0, x1, y1;
    double bg, nz, sw, sx, sy, pk = 0;
    for (it = 0; it < 3; it++) {
        x0 = (int)cx - r; y0 = (int)cy - r; x1 = (int)cx + r + 1; y1 = (int)cy + r + 1;
        if (x0 < 1 || y0 < 1 || x1 > g.fw - 1 || y1 > g.fh - 1) return 0;
        /* background from the box edge */
        {
            static __thread double e[1024]; int n = 0, k;
            for (x = x0; x < x1 && n < 1020; x++) { e[n++] = gd_px(f, x, y0); e[n++] = gd_px(f, x, y1 - 1); }
            for (y = y0; y < y1 && n < 1020; y++) { e[n++] = gd_px(f, x0, y); e[n++] = gd_px(f, x1 - 1, y); }
            qsort(e, n, sizeof(double), cmp_dbl); bg = e[n / 2];
            for (k = 0; k < n; k++) e[k] = fabs(e[k] - bg);
            qsort(e, n, sizeof(double), cmp_dbl); nz = e[n / 2] * 1.4826; if (nz < (g.bits16 ? 1 : 128)) nz = g.bits16 ? 1 : 128;
        }
        sw = sx = sy = 0; pk = 0;
        for (y = y0; y < y1; y++) for (x = x0; x < x1; x++) {
            double v = gd_px(f, x, y) - bg - 3 * nz;
            if (v > pk + 3 * nz) pk = v + 3 * nz;
            if (v <= 0) continue;
            sw += v; sx += v * x; sy += v * y;
        }
        if (sw <= 0) return 0;
        cx = sx / sw; cy = sy / sw;
    }
    *ox = cx; *oy = cy; *snr = pk / nz; *peak = pk + bg;
    return *snr > 6;
}

static void gd_hist_add(double r, double d)
{
    gd.hRA[gd.hPos] = r; gd.hDec[gd.hPos] = d;
    gd.hPos = (gd.hPos + 1) % GD_HIST;
    if (gd.hN < GD_HIST) gd.hN++;
}

/* ---- guide data log (CSV, one line per measured frame) ---------------
   Written next to the program as QBCap_guidedata.csv, so a bad night can
   be gone through afterwards: where the star was, the error, and every
   pulse that was sent. Lines starting with # are notes.                */
static FILE *gdLog;
static char gdLogPath[512];

static void gd_log_stamp(char *b, size_t n)
{
    struct timespec ts; struct tm tm;
    clock_gettime(CLOCK_REALTIME, &ts);
    localtime_r(&ts.tv_sec, &tm);
    snprintf(b, n, "%02d:%02d:%02d.%03d", tm.tm_hour % 100, tm.tm_min % 100, tm.tm_sec % 100, (int)(ts.tv_nsec / 1000000) % 1000);
}

static void gd_log_note(const char *s)
{
    char t[20];
    if (!gdLog) return;
    gd_log_stamp(t, sizeof t);
    fprintf(gdLog, "# %s  %s\n", t, s);
    fflush(gdLog);
}

static void gd_log_open(const char *why)
{
    time_t now; char d[40];
    if (!gdLogPath[0]) return;
    if (!gdLog) gdLog = fopen(gdLogPath, "a");
    if (!gdLog) return;
    now = time(NULL);
    strftime(d, sizeof d, "%Y-%m-%d %H:%M:%S", localtime(&now));
    fprintf(gdLog, "\n# ===== %s  %s =====\n", why, d);
    fprintf(gdLog, "# exposure %.2f s  aggRA %.0f%%  aggDec %.0f%%  min move %.2f px  max pulse %.0f ms  settle wait %.1f s\n",
            g.expUs / 1e6, gd.aggRA * 100, gd.aggDec * 100, gd.minMove, gd.maxPulse, GD_SETTLE_SEC);
    if (gd.calOk)
        fprintf(gdLog, "# calibration  RA %.2f px/s  Dec %.2f px/s  angle %.0f deg  ortho error %.0f deg\n",
                1000 * hypot(gd.vW[0], gd.vW[1]), 1000 * hypot(gd.vN[0], gd.vN[1]), gd.calAngle, gd.calOrtho);
    fflush(gdLog);
}

static void gd_log_close(void)
{
    if (gdLog) { fclose(gdLog); gdLog = NULL; }
}

/* calibration phases */
enum { CP_WEST = 1, CP_EAST, CP_CLEAR, CP_NORTH, CP_SOUTH };

static void gd_cal_frame(void)
{
    double dx = gd.x - gd.c0x, dy = gd.y - gd.c0y, dist = sqrt(dx * dx + dy * dy);
    char m[200];
    switch (gd.calPhase) {
    case CP_WEST:
    case CP_NORTH:
        if (dist >= gd.calDist || gd.calStepsDone >= gd.calMax) {
            double *v = gd.calPhase == CP_WEST ? gd.vW : gd.vN;
            if (dist < 3) {
                gd.state = GD_IDLE;
                snprintf(m, sizeof m, "Calibration failed: the star did not move when guiding %s - check the ST-4 cable (and that the mount is tracking).",
                         gd.calPhase == CP_WEST ? "West" : "North");
                gd_say(m); return;
            }
            v[0] = dx / (gd.calStepsDone * (double)gd.calMs);
            v[1] = dy / (gd.calStepsDone * (double)gd.calMs);
            gd.calSteps = gd.calStepsDone; gd.calStepsDone = 0;
            gd.calPhase = gd.calPhase == CP_WEST ? CP_EAST : CP_SOUTH;
            gd.c0x = gd.x; gd.c0y = gd.y;          /* the way back is measured too */
            snprintf(m, sizeof m, "Calibrating: %s done (%.1f px in %d steps), going back...", gd.calPhase == CP_EAST ? "West" : "North", dist, gd.calSteps);
            gd_say(m);
        }
        break;
    case CP_EAST:
    case CP_SOUTH:
        if (gd.calStepsDone >= gd.calSteps) {
            /* average the out and back legs: steady drift (tracking error) cancels */
            double *v = gd.calPhase == CP_EAST ? gd.vW : gd.vN;
            double bx = dx / (gd.calSteps * (double)gd.calMs), by = dy / (gd.calSteps * (double)gd.calMs);
            if (hypot(bx, by) > 0.3 * hypot(v[0], v[1])) { v[0] = (v[0] - bx) / 2; v[1] = (v[1] - by) / 2; }
            if (gd.calPhase == CP_EAST) {
                gd.calPhase = CP_CLEAR; gd.calStepsDone = 0; gd.c0x = gd.x; gd.c0y = gd.y;
                gd_say("Calibrating: clearing Dec backlash...");
            } else {
                double a1 = atan2(gd.vW[1], gd.vW[0]), a2 = atan2(gd.vN[1], gd.vN[0]), dif = (a2 - a1) * 180 / M_PI;
                while (dif > 180) dif -= 360;
                while (dif < -180) dif += 360;
                gd.calAngle = a1 * 180 / M_PI; gd.calOrtho = fabs(fabs(dif) - 90);
                gd.calOk = 1; gd.state = GD_IDLE;
                snprintf(m, sizeof m, "Calibration done: RA %.2f px/s, Dec %.2f px/s, angle %.0f deg%s",
                         1000 * hypot(gd.vW[0], gd.vW[1]), 1000 * hypot(gd.vN[0], gd.vN[1]), gd.calAngle,
                         gd.calOrtho > 20 ? " - axes not at right angles, calibrate again" : ".");
                gd_say(m);
            }
        }
        break;
    case CP_CLEAR:
        if (dist >= 3 || gd.calStepsDone >= 10) {
            gd.calPhase = CP_NORTH; gd.calStepsDone = 0; gd.c0x = gd.x; gd.c0y = gd.y;
            gd_say("Calibrating: North...");
        }
        break;
    }
    if (gd.state != GD_CAL) return;
    /* next step */
    switch (gd.calPhase) {
    case CP_WEST:  gd_pulse(ASI_GUIDE_WEST, gd.calMs); break;
    case CP_EAST:  gd_pulse(ASI_GUIDE_EAST, gd.calMs); break;
    case CP_CLEAR:
    case CP_NORTH: gd_pulse(ASI_GUIDE_NORTH, gd.calMs); break;
    case CP_SOUTH: gd_pulse(ASI_GUIDE_SOUTH, gd.calMs); break;
    }
    gd.calStepsDone++;
    gd.skip = 1;
    if (gdLog) {
        static const char *ph[] = { "", "W", "E", "clear", "N", "S" };
        char t[20];
        gd_log_stamp(t, sizeof t);
        fprintf(gdLog, "%s,cal,%s,%d,%.2f,%.2f,%.2f,%.2f,,,%d,,%.1f\n", t, ph[gd.calPhase], gd.calStepsDone,
                gd.x, gd.y, gd.x - gd.c0x, gd.y - gd.c0y, gd.calMs, gd.snr);
    }
}

static void gd_guide_frame(void)
{
    double dx = gd.x - gd.lockX, dy = gd.y - gd.lockY, det, a, b, lw, ln;
    int ra = 0, de = 0;
    /* star motion wanted = -d = a * vW + b * vN  (a, b in ms; a > 0 West, b > 0 North) */
    det = gd.vW[0] * gd.vN[1] - gd.vW[1] * gd.vN[0];
    if (fabs(det) < 1e-12) return;
    a = (-dx * gd.vN[1] + dy * gd.vN[0]) / det;
    b = (-dy * gd.vW[0] + dx * gd.vW[1]) / det;
    lw = hypot(gd.vW[0], gd.vW[1]); ln = hypot(gd.vN[0], gd.vN[1]);
    gd.eRA = -a * lw; gd.eDec = -b * ln;                     /* error in px along each axis */
    gd_hist_add(gd.eRA, gd.eDec);
    if (hypot(dx, dy) < gd.settlePx) { if (++gd.settleCnt >= 3) gd.settled = 1; } else gd.settleCnt = 0;
    if (gd.paused) {
        if (gdLog) {
            char t[20];
            gd_log_stamp(t, sizeof t);
            fprintf(gdLog, "%s,guide,paused,%ld,%.2f,%.2f,%.2f,%.2f,%.3f,%.3f,0,0,%.1f\n", t, gd.frames, gd.x, gd.y, dx, dy, gd.eRA, gd.eDec, gd.snr);
        }
        return;
    }
    if (fabs(gd.eRA) >= gd.minMove) ra = (int)(gd.aggRA * a);
    if (fabs(gd.eDec) >= gd.minMove) de = (int)(gd.aggDec * b);
    if (ra > gd.maxPulse) ra = gd.maxPulse;
    if (ra < -gd.maxPulse) ra = -gd.maxPulse;
    if (de > gd.maxPulse) de = gd.maxPulse;
    if (de < -gd.maxPulse) de = -gd.maxPulse;
    gd.lastRAms = ra; gd.lastDecms = de;
    if (ra > 0) gd_pulse(ASI_GUIDE_WEST, ra); else if (ra < 0) gd_pulse(ASI_GUIDE_EAST, -ra);
    if (de > 0) gd_pulse(ASI_GUIDE_NORTH, de); else if (de < 0) gd_pulse(ASI_GUIDE_SOUTH, -de);
    if (ra || de) gd.skip = 1;
    if (gdLog) {
        char t[20];
        gd_log_stamp(t, sizeof t);
        fprintf(gdLog, "%s,guide,%s,%ld,%.2f,%.2f,%.2f,%.2f,%.3f,%.3f,%d,%d,%.1f\n", t, gd.paused ? "paused" : "",
                gd.frames, gd.x, gd.y, dx, dy, gd.eRA, gd.eDec, ra, de, gd.snr);
    }
}

/* capture thread, every frame while the guider is enabled */
static void guide_frame(const uint8_t *f)
{
    double nx, ny, snr, pk;
    pthread_mutex_lock(&gd.mx);
    gd.frames++;
    if (gd.skip) {                          /* this frame was (partly) exposed during a pulse */
        if (!gd_busy() && now_sec() >= gd.quietUntil) gd.skip = 0;   /* this frame is still dropped; the next one counts */
        pthread_mutex_unlock(&gd.mx);
        return;
    }
    if (gd.have && gd_centroid(f, gd.x, gd.y, 12, &nx, &ny, &snr, &pk)) {
        gd.x = nx; gd.y = ny; gd.snr = snr; gd.peak = pk; gd.lost = 0;
    } else if (gd.have && ++gd.lost < 4) {
        pthread_mutex_unlock(&gd.mx);     /* one bad frame (cloud, seeing): wait */
        return;
    } else {
        double fx, fy;
        int ok;
        if (gd.have && gd.state != GD_IDLE) {
            gd_say(gd.state == GD_CAL ? "Star lost during calibration - stopped." : "STAR LOST - guiding stopped, looking for it again.");
            gd.state = GD_IDLE;
        }
        gd.have = 0;
        if (gd.selX >= 0) ok = gd_find(f, gd.selX - 40, gd.selY - 40, gd.selX + 40, gd.selY + 40, &fx, &fy);
        else ok = gd_find(f, 0, 0, g.fw, g.fh, &fx, &fy);
        if (ok && gd_centroid(f, fx, fy, 12, &nx, &ny, &snr, &pk)) {
            gd.x = nx; gd.y = ny; gd.snr = snr; gd.peak = pk; gd.have = 1; gd.lost = 0;
        }
        pthread_mutex_unlock(&gd.mx);
        return;
    }
    if (gd.state == GD_CAL) gd_cal_frame();
    else if (gd.state == GD_GUIDE) gd_guide_frame();
    pthread_mutex_unlock(&gd.mx);
}

/* ---- API ---- */
int qc_guide_enable(int on)
{
    if (on && !gd.pthrLive) {
        gd.pquit = 0;
        if (pthread_create(&gd.pthr, NULL, gd_pulse_thread, NULL) != 0) return fail_msg("guider: no thread");
        gd.pthrLive = 1;
    }
    if (!on) {
        pthread_mutex_lock(&gd.mx); gd.state = GD_IDLE; pthread_mutex_unlock(&gd.mx);
        if (gd.pthrLive) { gd.pquit = 1; pthread_join(gd.pthr, NULL); gd.pthrLive = 0; }
    }
    gd_on = on ? 1 : 0;
    return 0;
}

/* choose the guide star near a frame pixel (-1, -1 = brightest) */
int qc_guide_select(int x, int y)
{
    pthread_mutex_lock(&gd.mx);
    if (gd.state != GD_IDLE) { pthread_mutex_unlock(&gd.mx); return fail_msg("stop guiding first"); }
    gd.selX = x; gd.selY = y; gd.have = 0;
    pthread_mutex_unlock(&gd.mx);
    return 0;
}

int qc_guide_calibrate(int stepMs, int distPx)
{
    pthread_mutex_lock(&gd.mx);
    if (!gd.have) { pthread_mutex_unlock(&gd.mx); return fail_msg("no guide star yet"); }
    if (!g.info.ST4Port) { pthread_mutex_unlock(&gd.mx); return fail_msg("this camera has no ST-4 port"); }
    gd.calMs = stepMs > 50 ? stepMs : 750; gd.calDist = distPx > 4 ? distPx : 20;
    gd.calPhase = CP_WEST; gd.calStepsDone = 0; gd.c0x = gd.x; gd.c0y = gd.y; gd.calOk = 0;
    gd.state = GD_CAL; gd.skip = 0;
    gd_log_open("calibration");
    if (gdLog) fprintf(gdLog, "# time,kind,phase,step,x,y,dx,dy,,,pulse_ms,,snr\n");
    gd_say("Calibrating: West...");
    pthread_mutex_unlock(&gd.mx);
    return 0;
}

int qc_guide_start(void)
{
    pthread_mutex_lock(&gd.mx);
    if (!gd.calOk) { pthread_mutex_unlock(&gd.mx); return fail_msg("calibrate first"); }
    if (!gd.have) { pthread_mutex_unlock(&gd.mx); return fail_msg("no guide star"); }
    gd.lockX = gd.x; gd.lockY = gd.y; gd.state = GD_GUIDE; gd.paused = 0;
    gd.hN = 0; gd.hPos = 0; gd.settled = 0; gd.settleCnt = 0;
    gd_log_open("guiding");
    if (gdLog) fprintf(gdLog, "# time,kind,state,frame,x,y,dx,dy,errRA_px,errDec_px,ra_ms(+W/-E),dec_ms(+N/-S),snr  lock %.2f,%.2f\n", gd.lockX, gd.lockY);
    gd_say("Guiding.");
    pthread_mutex_unlock(&gd.mx);
    return 0;
}

int qc_guide_stop(void)
{
    pthread_mutex_lock(&gd.mx);
    gd.state = GD_IDLE; gd.paused = 0;
    gd_log_note("guiding stopped");
    gd_log_close();
    pthread_mutex_unlock(&gd.mx);
    return 0;
}

int qc_guide_pause(int on)
{
    pthread_mutex_lock(&gd.mx);
    gd.paused = on ? 1 : 0;
    if (!on) { gd.settled = 0; gd.settleCnt = 0; }
    pthread_mutex_unlock(&gd.mx);
    return 0;
}

/* move the lock point by up to +/- px (random), then wait for "settled" */
int qc_guide_dither(float px)
{
    pthread_mutex_lock(&gd.mx);
    if (gd.state != GD_GUIDE) { pthread_mutex_unlock(&gd.mx); return fail_msg("not guiding"); }
    gd.lockX += px * (2.0 * rand() / RAND_MAX - 1.0);
    gd.lockY += px * (2.0 * rand() / RAND_MAX - 1.0);
    gd.settled = 0; gd.settleCnt = 0;
    { char m[80]; snprintf(m, sizeof m, "dither: new lock %.2f, %.2f", gd.lockX, gd.lockY); gd_log_note(m); }
    pthread_mutex_unlock(&gd.mx);
    return 0;
}

/* where the guide data log goes ("" = no log) */
int qc_guide_logfile(const char *path)
{
    pthread_mutex_lock(&gd.mx);
    gd_log_close();
    snprintf(gdLogPath, sizeof gdLogPath, "%s", path ? path : "");
    pthread_mutex_unlock(&gd.mx);
    return 0;
}

int qc_guide_params(float aggRA, float aggDec, float minMovePx, int maxPulseMs, float settlePx)
{
    pthread_mutex_lock(&gd.mx);
    gd.aggRA = aggRA; gd.aggDec = aggDec; gd.minMove = minMovePx; gd.maxPulse = maxPulseMs; gd.settlePx = settlePx;
    if (gdLog) {
        char m[160];
        snprintf(m, sizeof m, "settings: aggRA %.0f%%  aggDec %.0f%%  min move %.2f px  max pulse %d ms", aggRA * 100, aggDec * 100, minMovePx, maxPulseMs);
        gd_log_note(m);
    }
    pthread_mutex_unlock(&gd.mx);
    return 0;
}

/* state: 0 idle, 1 calibrating, 2 guiding (paused flag separate). rms in px. */
int qc_guide_status(int *state, int *paused, int *haveStar, float *x, float *y, float *snr, float *lockX, float *lockY,
                    float *eRA, float *eDec, float *rmsRA, float *rmsDec, int *settled, int *calOk, int *raMs, int *decMs)
{
    int i; double sr = 0, sd = 0;
    pthread_mutex_lock(&gd.mx);
    *state = gd.state; *paused = gd.paused; *haveStar = gd.have; *x = gd.x; *y = gd.y; *snr = gd.snr;
    *lockX = gd.lockX; *lockY = gd.lockY; *eRA = gd.eRA; *eDec = gd.eDec;
    for (i = 0; i < gd.hN; i++) { sr += gd.hRA[i] * gd.hRA[i]; sd += gd.hDec[i] * gd.hDec[i]; }
    *rmsRA = gd.hN ? sqrt(sr / gd.hN) : 0; *rmsDec = gd.hN ? sqrt(sd / gd.hN) : 0;
    *settled = gd.settled; *calOk = gd.calOk; *raMs = gd.lastRAms; *decMs = gd.lastDecms;
    pthread_mutex_unlock(&gd.mx);
    return 0;
}

/* newest n errors (RA, Dec pairs in px), oldest first; returns count */
int qc_guide_history(float *buf, int n)
{
    int i, k, c;
    pthread_mutex_lock(&gd.mx);
    c = gd.hN < n ? gd.hN : n;
    for (i = 0; i < c; i++) {
        k = (gd.hPos - c + i + GD_HIST) % GD_HIST;
        buf[2 * i] = (float)gd.hRA[k]; buf[2 * i + 1] = (float)gd.hDec[k];
    }
    pthread_mutex_unlock(&gd.mx);
    return c;
}

int qc_guide_message(char *buf, int len)
{
    int s;
    pthread_mutex_lock(&gd.mx);
    copy_str(buf, len, gd.msg); s = gd.msgSeq;
    pthread_mutex_unlock(&gd.mx);
    return s;
}

/* calibration result: px per second West / North and their angles (deg) */
int qc_guide_cal_info(float *raPxS, float *decPxS, float *angle, float *ortho)
{
    *raPxS = 1000 * hypot(gd.vW[0], gd.vW[1]); *decPxS = 1000 * hypot(gd.vN[0], gd.vN[1]);
    *angle = gd.calAngle; *ortho = gd.calOrtho;
    return gd.calOk;
}

int qc_guide_has_st4(void) { return g.open ? (g.info.ST4Port ? 1 : 0) : -1; }

/* ---- link between the two QBCap copies (local UDP) ---- */
static int gl_fd = -1;

int qc_glink_listen(int port)
{
    struct sockaddr_in a;
    if (gl_fd >= 0) return 0;
    gl_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (gl_fd < 0) return fail_msg("link: no socket");
    memset(&a, 0, sizeof a); a.sin_family = AF_INET; a.sin_port = htons((uint16_t)port); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(gl_fd, (struct sockaddr *)&a, sizeof a) < 0) { close(gl_fd); gl_fd = -1; return fail_msg("link: port in use (is another guider running?)"); }
    fcntl(gl_fd, F_SETFL, O_NONBLOCK);
    return 0;
}

static struct sockaddr_in gl_from; static socklen_t gl_fromLen;

/* guider side: next message ("" if none) */
int qc_glink_poll(char *buf, int len)
{
    char in[256]; int n;
    if (gl_fd < 0) { copy_str(buf, len, ""); return 0; }
    gl_fromLen = sizeof gl_from;
    n = recvfrom(gl_fd, in, sizeof in - 1, 0, (struct sockaddr *)&gl_from, &gl_fromLen);
    if (n <= 0) { copy_str(buf, len, ""); return 0; }
    in[n] = 0; copy_str(buf, len, in);
    return n;
}

int qc_glink_reply(const char *msg)
{
    if (gl_fd < 0 || gl_fromLen == 0) return -1;
    sendto(gl_fd, msg, strlen(msg), 0, (struct sockaddr *)&gl_from, gl_fromLen);
    return 0;
}

/* main side: send a message, wait up to timeoutMs for the answer. 1 = answered, 0 = no guider */
int qc_glink_send(int port, const char *msg, char *reply, int len, int timeoutMs)
{
    static int fd = -1;
    struct sockaddr_in a; char in[256]; int n;
    struct timeval tv;
    if (fd < 0) { fd = socket(AF_INET, SOCK_DGRAM, 0); if (fd < 0) return 0; }
    tv.tv_sec = timeoutMs / 1000; tv.tv_usec = (timeoutMs % 1000) * 1000;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    while (recvfrom(fd, in, sizeof in, MSG_DONTWAIT, NULL, NULL) > 0) ;
    memset(&a, 0, sizeof a); a.sin_family = AF_INET; a.sin_port = htons((uint16_t)port); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sendto(fd, msg, strlen(msg), 0, (struct sockaddr *)&a, sizeof a);
    n = recvfrom(fd, in, sizeof in - 1, 0, NULL, NULL);
    if (n <= 0) { copy_str(reply, len, ""); return 0; }
    in[n] = 0; copy_str(reply, len, in);
    return 1;
}

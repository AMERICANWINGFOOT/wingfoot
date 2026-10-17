/*
 * pmcam.c  -  camera + star core for PoleMasterQB (QB64-PE front end)
 *
 *   - QHY PoleMaster capture: libqhyccd.so is loaded at run time (dlopen)
 *     from this library's own folder, or from the system. Same tested code
 *     path as QBCap step 9: single exposures in a loop on a background
 *     thread, 8-bit transfer, newest frame kept as 16-bit samples.
 *   - Simulator: the front end hands over a list of star pixel positions
 *     and magnitudes; a thread renders noisy frames from them, so the whole
 *     alignment procedure can be rehearsed in daylight.
 *   - Stretched preview drawn straight into a QB64 32-bit image (_MemImage).
 *   - Star finder (list of centroids, brightest first) and a single-star
 *     centroid near a clicked point.
 *
 * All exported functions use int / double / float* / char* / void* so they
 * map cleanly onto QB64 Long, Double, Single and _Offset.
 *
 * Build:  sh build_pmcam.sh
 *   gcc -O2 -Wall -shared -fPIC -o libpmcam.so pmcam.c -lpthread -lm -ldl
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
#include <dlfcn.h>

#define PM_VERSION 1

/* ------------------------------------------------------------------ */
/* shared state                                                        */
/* ------------------------------------------------------------------ */
typedef void qhy_handle;

static struct {
    /* QHY library */
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
    uint32_t (*SetRes)(qhy_handle *, uint32_t, uint32_t, uint32_t, uint32_t);
    uint32_t (*MemLen)(qhy_handle *);
    uint32_t (*Expose)(qhy_handle *);
    uint32_t (*GetFrame)(qhy_handle *, uint32_t *, uint32_t *, uint32_t *, uint32_t *, uint8_t *);
    uint32_t (*Chip)(qhy_handle *, double *, double *, uint32_t *, uint32_t *, double *, double *, uint32_t *);
    uint32_t (*Bits)(qhy_handle *, uint32_t);
    uint32_t (*Bin)(qhy_handle *, uint32_t, uint32_t);
    uint32_t (*Cancel)(qhy_handle *);
    void (*LogLevel)(uint8_t);
    int resInit;

    /* camera / simulator */
    qhy_handle *h;
    int mode;                    /* 0 closed, 1 PoleMaster, 2 simulator */
    char name[64];
    int w, h_;
    pthread_t thr;
    int threadLive;
    volatile int quit;
    volatile int expMs, gain, settingsDirty;
    pthread_mutex_t mx;
    uint8_t *raw;                /* SDK buffer */
    uint16_t *frame;             /* newest complete frame (16-bit samples) */
    size_t memLen;
    volatile unsigned seq;
    unsigned shownSeq;
    volatile int errors;
    volatile int saturated;
    double bg, noise;            /* background level / noise of the newest frame */
    unsigned statsSeq;

    /* simulator scene */
    pthread_mutex_t simMx;
    float *simX, *simY, *simM;
    int simN;
    unsigned simRng;

    char err[200];
} pm = { .mx = PTHREAD_MUTEX_INITIALIZER, .simMx = PTHREAD_MUTEX_INITIALIZER,
         .expMs = 1000, .gain = 40, .simRng = 12345u };

enum { QHY_GAIN = 6, QHY_OFFSET = 7, QHY_EXPOSURE = 8, QHY_TRANSFERBIT = 10, QHY_USBTRAFFIC = 12 };

static int fail_msg(const char *msg)
{
    snprintf(pm.err, sizeof pm.err, "%s", msg);
    return -1;
}

static void copy_str(char *dst, int len, const char *src)
{
    if (!dst || len <= 0) return;
    snprintf(dst, (size_t)len, "%s", src ? src : "");
}

/* text of the last error */
int pm_last_error(char *buf, int len)
{
    copy_str(buf, len, pm.err);
    return (int)strlen(pm.err);
}

int pm_version(void) { return PM_VERSION; }

/* UTC now, seconds since 1970 (with fractions) */
double pm_utc(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (double)ts.tv_sec + ts.tv_nsec * 1e-9;
}

/* ------------------------------------------------------------------ */
/* QHY library loading                                                 */
/* ------------------------------------------------------------------ */
static int pm_load(void)
{
    const char *names[4] = { NULL, "libqhyccd.so", "libqhyccd.so.20", NULL };
    char own[1024];
    Dl_info di;
    int i;
    if (pm.lib) return 0;
    if (dladdr((void *)pm_load, &di) && di.dli_fname) {   /* the folder libpmcam.so lives in */
        const char *slash = strrchr(di.dli_fname, '/');
        if (slash) { snprintf(own, sizeof own, "%.*s/libqhyccd.so", (int)(slash - di.dli_fname), di.dli_fname); names[0] = own; }
    }
    for (i = 0; i < 3 && !pm.lib; i++) if (names[i]) pm.lib = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
    if (!pm.lib) return fail_msg("QHY library not found - put libqhyccd.so in the program folder");
#define PMSYM(f, n) if (!(*(void **)(&pm.f) = dlsym(pm.lib, n))) { snprintf(pm.err, sizeof pm.err, "libqhyccd.so is missing %s", n); dlclose(pm.lib); pm.lib = NULL; return -1; }
    PMSYM(Init, "InitQHYCCDResource") PMSYM(Release, "ReleaseQHYCCDResource") PMSYM(Scan, "ScanQHYCCD")
    PMSYM(GetId, "GetQHYCCDId") PMSYM(GetModel, "GetQHYCCDModel") PMSYM(Open, "OpenQHYCCD") PMSYM(Close, "CloseQHYCCD")
    PMSYM(StreamMode, "SetQHYCCDStreamMode") PMSYM(InitCam, "InitQHYCCD") PMSYM(SetParam, "SetQHYCCDParam")
    PMSYM(SetRes, "SetQHYCCDResolution") PMSYM(MemLen, "GetQHYCCDMemLength")
    PMSYM(Expose, "ExpQHYCCDSingleFrame") PMSYM(GetFrame, "GetQHYCCDSingleFrame") PMSYM(Chip, "GetQHYCCDChipInfo")
    PMSYM(Bits, "SetQHYCCDBitsMode") PMSYM(Bin, "SetQHYCCDBinMode") PMSYM(Cancel, "CancelQHYCCDExposingAndReadout")
#undef PMSYM
    pm.LogLevel = (void (*)(uint8_t))dlsym(pm.lib, "SetQHYCCDLogLevel");
    if (pm.LogLevel) pm.LogLevel(2);             /* errors only - the SDK is chatty */
    return 0;
}

/* ------------------------------------------------------------------ */
/* capture threads                                                     */
/* ------------------------------------------------------------------ */
static void *cam_thread(void *arg)
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
        if ((int)w != pm.w || (int)h != pm.h_) { pm.errors++; continue; }
        pthread_mutex_lock(&pm.mx);
        if (bpp == 16) memcpy(pm.frame, pm.raw, (size_t)w * h * 2);
        else {
            size_t i, n = (size_t)w * h;
            for (i = 0; i < n; i++) pm.frame[i] = (uint16_t)(pm.raw[i] << 8);
        }
        pm.seq++;
        pthread_mutex_unlock(&pm.mx);
    }
    return NULL;
}

/* simple random numbers for the simulator */
static double sim_uniform(void)
{
    pm.simRng = pm.simRng * 1664525u + 1013904223u;
    return ((pm.simRng >> 8) + 0.5) / 16777216.0;
}
static double sim_gauss(void)
{
    double u = sim_uniform(), v = sim_uniform();
    return sqrt(-2.0 * log(u)) * cos(6.283185307179586 * v);
}

static void *sim_thread(void *arg)
{
    float *img;
    int W = pm.w, H = pm.h_;
    (void)arg;
    img = (float *)malloc((size_t)W * H * sizeof(float));
    if (!img) return NULL;
    while (!pm.quit) {
        int e = pm.expMs, g = pm.gain, i, k;
        double gainF = pow(10.0, g / 50.0);            /* about x10 per 50 gain steps */
        double bgLevel = 1500.0 + 0.9 * e * gainF;     /* sky + bias, 16-bit units */
        double rn = 180.0 * (0.5 + gainF * 0.15);      /* read noise */
        double t0 = pm_utc();
        if (bgLevel > 60000) bgLevel = 60000;
        for (i = 0; i < W * H; i++) img[i] = (float)(bgLevel + rn * sim_gauss());
        pthread_mutex_lock(&pm.simMx);
        for (k = 0; k < pm.simN; k++) {
            /* flux: at 1 s, gain 40 a mag 8 star peaks about 5x the noise (like the real one) */
            double flux = 5.7e6 * pow(10.0, -0.4 * (pm.simM[k] - 2.0)) * (e / 1000.0) * gainF / 6.3;
            double sx = pm.simX[k], sy = pm.simY[k], sig = 1.35, a = flux / (6.283185307179586 * sig * sig);
            int x0 = (int)floor(sx) - 5, y0 = (int)floor(sy) - 5, x, y;
            if (sx < -6 || sy < -6 || sx > W + 6 || sy > H + 6) continue;
            for (y = y0; y <= y0 + 11; y++) {
                if (y < 0 || y >= H) continue;
                for (x = x0; x <= x0 + 11; x++) {
                    double dx = x - sx, dy = y - sy;
                    if (x < 0 || x >= W) continue;
                    img[(size_t)y * W + x] += (float)(a * exp(-(dx * dx + dy * dy) / (2 * sig * sig)));
                }
            }
        }
        pthread_mutex_unlock(&pm.simMx);
        /* a few hot pixels, always in the same places */
        for (k = 0; k < 40; k++) {
            int x = (k * 7919) % W, y = (k * 104729) % H;
            img[(size_t)y * W + x] += 30000.0f;
        }
        pthread_mutex_lock(&pm.mx);
        for (i = 0; i < W * H; i++) {
            double v = img[i];
            if (v < 0) v = 0;
            if (v > 65535) v = 65535;
            pm.frame[i] = (uint16_t)((int)v & 0xFF00);   /* 8-bit camera, like the real one */
        }
        pm.seq++;
        pthread_mutex_unlock(&pm.mx);
        /* wait the rest of the exposure time (in small steps so close is quick) */
        while (!pm.quit && (pm_utc() - t0) * 1000.0 < (e > 50 ? e : 50)) usleep(20000);
    }
    free(img);
    return NULL;
}

void pm_close(void);

/* find and open a QHY PoleMaster (or, if none, any single QHY camera).
 * Returns 0 ok, -1 error (pm_last_error). */
int pm_open(void)
{
    uint32_t n, i, imw = 0, imh = 0, bpp = 0;
    char id[64], model[64], pick[64] = "";
    double cw, chh, pw = 0, ph;
    if (pm.mode) return 0;
    if (pm_load() != 0) return -1;
    if (!pm.resInit) { if (pm.Init() != 0) return fail_msg("QHY library would not start"); pm.resInit = 1; }
    n = pm.Scan();
    if (n == 0 || n > 16) return fail_msg("no PoleMaster found on USB (plugged in? QHY firmware + USB rule installed?)");
    for (i = 0; i < n; i++) {
        memset(id, 0, sizeof id);
        if (pm.GetId(i, id) != 0) continue;
        if (!pick[0]) snprintf(pick, sizeof pick, "%s", id);
        if (strstr(id, "POLE") || strstr(id, "Pole") || strstr(id, "pole")) { snprintf(pick, sizeof pick, "%s", id); break; }
    }
    if (!pick[0]) return fail_msg("could not read the QHY camera id");
    pm.h = pm.Open(pick);
    if (!pm.h) return fail_msg("PoleMaster found but would not open (USB permissions? close Ekos / PHD2 first)");
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
    pm.frame = (uint16_t *)calloc((size_t)imw * imh, 2);
    if (!pm.raw || !pm.frame) { free(pm.raw); free(pm.frame); pm.raw = NULL; pm.frame = NULL; pm.Close(pm.h); pm.h = NULL; return fail_msg("out of memory"); }
    pm.w = (int)imw; pm.h_ = (int)imh;
    memset(model, 0, sizeof model);
    if (pm.GetModel(pick, model) == 0 && model[0]) snprintf(pm.name, sizeof pm.name, "%s", model);
    else snprintf(pm.name, sizeof pm.name, "%.40s", pick);
    pm.seq = 0; pm.shownSeq = 0; pm.statsSeq = 0; pm.errors = 0; pm.quit = 0; pm.settingsDirty = 1;
    pm.mode = 1;
    if (pthread_create(&pm.thr, NULL, cam_thread, NULL)) { pm_close(); return fail_msg("could not start the capture thread"); }
    pm.threadLive = 1;
    return 0;
}

/* simulated PoleMaster (w x h). Stars come from pm_sim_stars. */
int pm_open_sim(int w, int h)
{
    if (pm.mode) return 0;
    if (w < 64 || h < 64 || w > 8192 || h > 8192) return fail_msg("bad simulator size");
    pm.frame = (uint16_t *)calloc((size_t)w * h, 2);
    if (!pm.frame) return fail_msg("out of memory");
    pm.w = w; pm.h_ = h;
    snprintf(pm.name, sizeof pm.name, "Simulator");
    pm.seq = 0; pm.shownSeq = 0; pm.statsSeq = 0; pm.errors = 0; pm.quit = 0;
    pm.mode = 2;
    if (pthread_create(&pm.thr, NULL, sim_thread, NULL)) { pm_close(); return fail_msg("could not start the simulator thread"); }
    pm.threadLive = 1;
    return 0;
}

void pm_close(void)
{
    if (!pm.mode) return;
    pm.quit = 1;
    if (pm.mode == 1 && pm.Cancel && pm.h) pm.Cancel(pm.h);
    if (pm.threadLive) { pthread_join(pm.thr, NULL); pm.threadLive = 0; }
    if (pm.mode == 1 && pm.h) pm.Close(pm.h);
    pm.h = NULL;
    pthread_mutex_lock(&pm.mx);
    free(pm.raw); free(pm.frame); pm.raw = NULL; pm.frame = NULL;
    pthread_mutex_unlock(&pm.mx);
    pm.mode = 0;
    pm.seq = 0;
}

/* 0 closed, 1 PoleMaster, 2 simulator */
int pm_is_open(void) { return pm.mode; }

/* exposure in ms, gain 0-100 */
int pm_set(int expMs, int gain)
{
    if (expMs < 1) expMs = 1;
    if (expMs > 10000) expMs = 10000;
    if (gain < 0) gain = 0;
    if (gain > 100) gain = 100;
    pm.expMs = expMs; pm.gain = gain; pm.settingsDirty = 1;
    return 0;
}

/* name, frame size, frames taken, saturated flag, error count. Returns mode. */
int pm_info(char *name, int len, int *w, int *h, int *frames, int *saturated, int *errors)
{
    copy_str(name, len, pm.mode ? pm.name : "");
    *w = pm.w; *h = pm.h_; *frames = (int)pm.seq; *saturated = pm.saturated; *errors = pm.errors;
    return pm.mode;
}

/* simulator scene: star pixel positions (frame pixels) and magnitudes */
int pm_sim_stars(const float *xs, const float *ys, const float *mags, int n)
{
    int k;
    if (n < 0) n = 0;
    if (n > 5000) n = 5000;
    pthread_mutex_lock(&pm.simMx);
    free(pm.simX); free(pm.simY); free(pm.simM);
    pm.simX = pm.simY = pm.simM = NULL; pm.simN = 0;
    if (n > 0) {
        pm.simX = (float *)malloc(n * sizeof(float));
        pm.simY = (float *)malloc(n * sizeof(float));
        pm.simM = (float *)malloc(n * sizeof(float));
        if (pm.simX && pm.simY && pm.simM) {
            for (k = 0; k < n; k++) { pm.simX[k] = xs[k]; pm.simY[k] = ys[k]; pm.simM[k] = mags[k]; }
            pm.simN = n;
        }
    }
    pthread_mutex_unlock(&pm.simMx);
    return pm.simN;
}

/* ------------------------------------------------------------------ */
/* background / noise of the newest frame (call with pm.mx held)       */
/* ------------------------------------------------------------------ */
static void frame_stats(void)
{
    static int hist[4096];
    int i, n = 0, acc = 0, med = 0, mad = 0, W = pm.w, H = pm.h_, step;
    static int dev[4096];
    if (pm.statsSeq == pm.seq) return;
    pm.statsSeq = pm.seq;
    memset(hist, 0, sizeof hist);
    step = (W * H) / 60000 + 1;
    for (i = 0; i < W * H; i += step) { hist[pm.frame[i] >> 4]++; n++; }
    for (i = 0; i < 4096; i++) { acc += hist[i]; if (acc >= n / 2) { med = i; break; } }
    memset(dev, 0, sizeof dev);
    for (i = 0; i < 4096; i++) if (hist[i]) dev[abs(i - med)] += hist[i];
    acc = 0;
    for (i = 0; i < 4096; i++) { acc += dev[i]; if (acc >= n / 2) { mad = i; break; } }
    pm.bg = med * 16.0 + 8.0;
    pm.noise = 1.4826 * mad * 16.0;
    if (pm.noise < 64.0) pm.noise = 64.0;      /* 8-bit data: one count = 256 */
    acc = 0;
    for (i = 4000; i < 4096; i++) acc += hist[i];
    pm.saturated = (acc > n / 2);
}

/* ------------------------------------------------------------------ */
/* preview                                                             */
/* ------------------------------------------------------------------ */
/* draw the newest frame into a BGRA image. dx,dy,dw,dh = where in the
 * image; sx,sy,sw,sh = which part of the frame (zoom). stretch: 0 auto
 * star stretch, 1 linear (as is). Returns 1 if a new frame was drawn. */
int pm_preview(void *bgra, int imgW, int imgH, int dx, int dy, int dw, int dh,
               int sx, int sy, int sw, int sh, int force, int stretch)
{
    uint32_t *dst = (uint32_t *)bgra;
    static uint8_t lut[4096];
    int x, y, W, H, lo, hi, i;
    const uint16_t *f;
    if (!pm.mode || !pm.frame || pm.seq == 0) return 0;
    if (pm.seq == pm.shownSeq && !force) return 0;
    pthread_mutex_lock(&pm.mx);
    if (!pm.frame) { pthread_mutex_unlock(&pm.mx); return 0; }
    pm.shownSeq = pm.seq;
    W = pm.w; H = pm.h_;
    f = pm.frame;
    frame_stats();
    lo = (int)(pm.bg / 16.0) - 2;
    hi = (int)((pm.bg + 40.0 * pm.noise) / 16.0);
    if (stretch == 1 || hi - lo < 24 || pm.saturated) {
        for (i = 0; i < 4096; i++) lut[i] = (uint8_t)(i >> 4);
    } else {
        if (lo < 0) lo = 0;
        if (hi > 4095) hi = 4095;
        if (hi <= lo) hi = lo + 1;
        for (i = 0; i < 4096; i++) {
            double t = (double)(i - lo) / (hi - lo);
            if (t < 0) t = 0;
            if (t > 1) t = 1;
            lut[i] = (uint8_t)(255.0 * pow(t, 0.5));
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

/* ------------------------------------------------------------------ */
/* stars                                                               */
/* ------------------------------------------------------------------ */
/* centroid of the blob around (cx, cy) in a (2r+1) box, background bg.
 * Writes the result and returns the flux (0 if nothing). */
static double centroid_at(int cx, int cy, int r, double bg, double *ox, double *oy)
{
    int x, y, W = pm.w, H = pm.h_;
    double sx = 0, sy = 0, s = 0;
    for (y = cy - r; y <= cy + r; y++) {
        if (y < 0 || y >= H) continue;
        for (x = cx - r; x <= cx + r; x++) {
            double v;
            if (x < 0 || x >= W) continue;
            v = pm.frame[(size_t)y * W + x] - bg;
            if (v <= 0) continue;
            sx += v * x; sy += v * y; s += v;
        }
    }
    if (s <= 0) return 0;
    *ox = sx / s; *oy = sy / s;
    return s;
}

/* is (x, y) a real star peak and not a lone hot pixel? */
static int real_peak(int x, int y, double thr)
{
    int W = pm.w, n = 0, i, j;
    for (j = -1; j <= 1; j++)
        for (i = -1; i <= 1; i++)
            if (pm.frame[(size_t)(y + j) * W + x + i] > thr) n++;
    return n >= 3;
}

/* find stars in the newest frame: centroids + flux, brightest first.
 * Returns the count (0..maxN); *seq = the frame number used. */
int pm_find_stars(float *xs, float *ys, float *flux, int maxN, int *seq)
{
    int W, H, x, y, n = 0, i, j, k;
    double thr, half;
    *seq = 0;
    if (!pm.mode || !pm.frame || pm.seq == 0 || maxN <= 0) return 0;
    pthread_mutex_lock(&pm.mx);
    if (!pm.frame) { pthread_mutex_unlock(&pm.mx); return 0; }
    W = pm.w; H = pm.h_;
    frame_stats();
    *seq = (int)pm.seq;
    thr = pm.bg + 6.0 * pm.noise;
    if (thr < pm.bg + 600) thr = pm.bg + 600;
    for (y = 5; y < H - 5; y++) {
        const uint16_t *row = pm.frame + (size_t)y * W;
        for (x = 5; x < W - 5; x++) {
            double v = row[x], ox, oy, fl;
            int isMax = 1;
            if (v <= thr) continue;
            /* local maximum in a 7x7 box (ties: first one wins) */
            for (j = -3; j <= 3 && isMax; j++)
                for (i = -3; i <= 3; i++) {
                    double u;
                    if (!i && !j) continue;
                    u = pm.frame[(size_t)(y + j) * W + x + i];
                    if (u > v || (u == v && (j < 0 || (j == 0 && i < 0)))) { isMax = 0; break; }
                }
            if (!isMax) continue;
            half = pm.bg + (v - pm.bg) * 0.25;
            if (!real_peak(x, y, half)) continue;
            fl = centroid_at(x, y, 5, pm.bg + 2.0 * pm.noise, &ox, &oy);
            if (fl <= 0) continue;
            /* re-centre the box on the first estimate (matters for big / saturated stars) */
            {
                double ox2 = ox, oy2 = oy, f2;
                f2 = centroid_at((int)floor(ox + 0.5), (int)floor(oy + 0.5), 5, pm.bg + 2.0 * pm.noise, &ox2, &oy2);
                if (f2 > 0) { ox = ox2; oy = oy2; fl = f2; }
            }
            /* insert, keeping the list sorted by flux */
            if (n < maxN) n++;
            else if (fl <= flux[n - 1]) continue;
            for (k = n - 1; k > 0 && flux[k - 1] < fl; k--) { xs[k] = xs[k - 1]; ys[k] = ys[k - 1]; flux[k] = flux[k - 1]; }
            xs[k] = (float)ox; ys[k] = (float)oy; flux[k] = (float)fl;
        }
    }
    pthread_mutex_unlock(&pm.mx);
    return n;
}

/* centroid of the brightest star within radius r of (x0, y0).
 * Returns 1 if found (writes x, y, flux), 0 if not. */
int pm_centroid(double x0, double y0, int r, double *x, double *y, double *flux)
{
    int W, H, cx, cy, bx = -1, by = -1, i, j, it;
    double best = -1, ox, oy, fl;
    if (!pm.mode || !pm.frame || pm.seq == 0) return 0;
    pthread_mutex_lock(&pm.mx);
    if (!pm.frame) { pthread_mutex_unlock(&pm.mx); return 0; }
    W = pm.w; H = pm.h_;
    frame_stats();
    /* brightest 3x3 sum in the search circle (ignores single hot pixels) */
    for (cy = (int)y0 - r; cy <= (int)y0 + r; cy++) {
        if (cy < 2 || cy >= H - 2) continue;
        for (cx = (int)x0 - r; cx <= (int)x0 + r; cx++) {
            double s = 0, mx = 0;
            if (cx < 2 || cx >= W - 2) continue;
            if ((cx - x0) * (cx - x0) + (cy - y0) * (cy - y0) > (double)r * r) continue;
            for (j = -1; j <= 1; j++)
                for (i = -1; i <= 1; i++) {
                    double v = pm.frame[(size_t)(cy + j) * W + cx + i];
                    s += v;
                    if (v > mx) mx = v;
                }
            s -= mx * 0.5;                   /* a lone hot pixel scores low */
            if (s > best) { best = s; bx = cx; by = cy; }
        }
    }
    if (bx < 0 || best / 8.5 < pm.bg + 4.0 * pm.noise) { pthread_mutex_unlock(&pm.mx); return 0; }
    ox = bx; oy = by; fl = 0;
    for (it = 0; it < 3; it++) {
        fl = centroid_at((int)floor(ox + 0.5), (int)floor(oy + 0.5), 5, pm.bg + 2.0 * pm.noise, &ox, &oy);
        if (fl <= 0) break;
    }
    pthread_mutex_unlock(&pm.mx);
    if (fl <= 0) return 0;
    *x = ox; *y = oy; *flux = fl;
    return 1;
}

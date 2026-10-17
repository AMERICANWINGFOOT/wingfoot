/* ==================================================================
   linabench.h - Linabench v1.4 render kernel (Linux, pthreads)
   Header-only C, pulled in by the QB64-PE Declare Library block in
   Linabench.bas. QB64 compiles it as C++, so it stays C++-clean.

   Fixed scene: 35 small spheres + 3 big mirrors on a checker floor,
   one square area light (8 soft-shadow samples), reflections up to 4 deep,
   8x8 supersampling. 960x540 image in 32x32 tiles, rendered from the
   center outward. Every pixel has its own deterministic RNG seed, so
   the finished image is bit-identical at any thread count - the
   checksum proves the run did the same work every time.
   ================================================================== */
#ifndef LINABENCH_H
#define LINABENCH_H

#include <pthread.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/file.h>

/* QB64-PE builds at -O0 unless its C++ optimization option is on.
   Force -O2 for this kernel only, and force the small math helpers
   inline (the -O0 pass skips the inliner otherwise). pop_options at
   the end keeps this from touching the rest of the QB64 program. */
#pragma GCC push_options
#pragma GCC optimize ("O2")
#define LBINL inline __attribute__((always_inline))

#define LB_W        960
#define LB_H        540
#define LB_TILE     32
#define LB_TX       ((LB_W + LB_TILE - 1) / LB_TILE)
#define LB_TY       ((LB_H + LB_TILE - 1) / LB_TILE)
#define LB_NTILES   (LB_TX * LB_TY)
#define LB_SPP      8      /* 8x8 = 64 samples per pixel      */
#define LB_DEPTH    4      /* primary + 3 reflection bounces  */
#define LB_SHADOWS  8      /* area-light samples per hit      */
#define LB_MAXT     256
#define LB_NSPH_MAX 64
#define LB_EPS      1e-4

/* ---------------- vector math ---------------- */
typedef struct { double x, y, z; } LBV;
static LBINL LBV lbv(double x, double y, double z) { LBV r; r.x = x; r.y = y; r.z = z; return r; }
static LBINL LBV lb_add(LBV a, LBV b) { return lbv(a.x + b.x, a.y + b.y, a.z + b.z); }
static LBINL LBV lb_sub(LBV a, LBV b) { return lbv(a.x - b.x, a.y - b.y, a.z - b.z); }
static LBINL LBV lb_mul(LBV a, double s) { return lbv(a.x * s, a.y * s, a.z * s); }
static LBINL LBV lb_mulv(LBV a, LBV b) { return lbv(a.x * b.x, a.y * b.y, a.z * b.z); }
static LBINL double lb_dot(LBV a, LBV b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static LBINL LBV lb_norm(LBV a) { return lb_mul(a, 1.0 / sqrt(lb_dot(a, a))); }
static LBINL LBV lb_cross(LBV a, LBV b) {
    return lbv(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
}

/* ---------------- deterministic RNG ---------------- */
static LBINL uint32_t lb_hash(uint32_t x) {
    x ^= x >> 16; x *= 0x7feb352dU; x ^= x >> 15; x *= 0x846ca68bU; x ^= x >> 16;
    return x;
}
static LBINL double lb_rnd(uint32_t *s) {
    uint32_t x = *s;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    *s = x;
    return (x >> 8) * (1.0 / 16777216.0);
}

/* ---------------- state ---------------- */
typedef struct { LBV c; double r; LBV col; double refl; } LBSphere;
typedef struct { uint64_t rays; char pad[56]; } LBCount;   /* one cache line each */

static LBSphere lb_sph[LB_NSPH_MAX];
static int lb_nsph = 0;
static int lb_order[LB_NTILES];
static volatile int lb_state[LB_NTILES];   /* 0 pending, 1 rendering, 2 done */
static uint32_t *lb_buf = 0;
static pthread_t lb_th[LB_MAXT];
static LBCount lb_cnt[LB_MAXT];
static int lb_nth = 0;
static int lb_next = 0, lb_done_n = 0, lb_stop = 0, lb_active = 0, lb_ready = 0;
static double lb_t0 = 0, lb_t1 = 0, lb_last = 0;
static LBV lb_cam, lb_cu, lb_cv, lb_cw;
static double lb_half_w, lb_half_h;
static char lb_model[128];
static char lb_tpath[256];
static int lb_tsearched = 0;

double lb_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec * 1e-9;
}

/* ---------------- scene setup ---------------- */
static void lb_setup(void) {
    int r, c, i, j;
    uint32_t h;
    double dist[LB_NTILES];

    lb_nsph = 0;
    for (r = 0; r < 5; r++) {
        for (c = 0; c < 7; c++) {
            LBSphere *s = &lb_sph[lb_nsph++];
            h = lb_hash((uint32_t)(r * 7 + c + 1));
            s->r = 0.45;
            s->c = lbv(-4.5 + c * 1.5, 0.45, -1.5 + r * 1.5);
            s->col = lbv(0.25 + 0.75 * ((h & 255) / 255.0),
                         0.25 + 0.75 * (((h >> 8) & 255) / 255.0),
                         0.25 + 0.75 * (((h >> 16) & 255) / 255.0));
            s->refl = (((h >> 24) & 3) == 0) ? 0.7 : 0.15;
        }
    }
    for (c = 0; c < 3; c++) {
        LBSphere *s = &lb_sph[lb_nsph++];
        s->r = 1.4;
        s->c = lbv(-3.5 + c * 3.5, 1.4, 7.5);
        s->col = (c == 0) ? lbv(0.9, 0.9, 0.95) : (c == 1) ? lbv(1.0, 0.8, 0.35) : lbv(0.95, 0.55, 0.4);
        s->refl = (c == 1) ? 0.85 : 0.6;
    }

    /* camera */
    {
        LBV look = lbv(0.0, 0.9, 2.5);
        LBV up = lbv(0.0, 1.0, 0.0);
        lb_cam = lbv(0.0, 3.4, -9.5);
        lb_cw = lb_norm(lb_sub(look, lb_cam));
        lb_cu = lb_norm(lb_cross(up, lb_cw));
        lb_cv = lb_cross(lb_cw, lb_cu);
        lb_half_h = tan(48.0 * 3.14159265358979 / 360.0);
        lb_half_w = lb_half_h * (double)LB_W / (double)LB_H;
    }

    /* tile order: nearest the image center first */
    for (i = 0; i < LB_NTILES; i++) {
        double dx = (i % LB_TX) * LB_TILE + LB_TILE / 2 - LB_W / 2;
        double dy = (i / LB_TX) * LB_TILE + LB_TILE / 2 - LB_H / 2;
        dist[i] = dx * dx + dy * dy;
        lb_order[i] = i;
    }
    for (i = 1; i < LB_NTILES; i++) {
        int k = lb_order[i];
        j = i - 1;
        while (j >= 0 && dist[lb_order[j]] > dist[k]) { lb_order[j + 1] = lb_order[j]; j--; }
        lb_order[j + 1] = k;
    }
    lb_ready = 1;
}

/* ---------------- tracing ---------------- */
/* nearest hit: idx -1 = floor, >=0 = sphere; returns 1 on hit */
static LBINL int lb_hit(LBV ro, LBV rd, double tmax, double *tout, int *idx) {
    double best = tmax;
    int bi = -2, i;
    if (rd.y < -1e-9) {
        double t = -ro.y / rd.y;
        if (t > LB_EPS && t < best) { best = t; bi = -1; }
    }
    for (i = 0; i < lb_nsph; i++) {
        LBV oc = lb_sub(ro, lb_sph[i].c);
        double b = lb_dot(oc, rd);
        double cc = lb_dot(oc, oc) - lb_sph[i].r * lb_sph[i].r;
        double disc = b * b - cc;
        if (disc > 0) {
            double sq = sqrt(disc);
            double t = -b - sq;
            if (t < LB_EPS) t = -b + sq;
            if (t > LB_EPS && t < best) { best = t; bi = i; }
        }
    }
    if (bi == -2) return 0;
    *tout = best;
    *idx = bi;
    return 1;
}

static LBV lb_trace(LBV ro, LBV rd, uint64_t *rays, uint32_t *rng) {
    LBV acc = lbv(0, 0, 0), thr = lbv(1, 1, 1);
    int d, s, idx;
    double t;

    for (d = 0; d < LB_DEPTH; d++) {
        (*rays)++;
        if (!lb_hit(ro, rd, 1e30, &t, &idx)) {
            double k = 0.5 * (rd.y + 1.0);
            LBV sky = lb_add(lb_mul(lbv(0.85, 0.80, 0.75), 1.0 - k), lb_mul(lbv(0.25, 0.45, 0.85), k));
            acc = lb_add(acc, lb_mulv(thr, sky));
            break;
        }

        LBV p = lb_add(ro, lb_mul(rd, t));
        LBV n, base;
        double refl;
        if (idx < 0) {
            int chk = ((int)floor(p.x) + (int)floor(p.z)) & 1;
            n = lbv(0, 1, 0);
            base = chk ? lbv(0.85, 0.85, 0.85) : lbv(0.12, 0.12, 0.14);
            refl = 0.25;
        } else {
            n = lb_norm(lb_sub(p, lb_sph[idx].c));
            base = lb_sph[idx].col;
            refl = lb_sph[idx].refl;
        }
        LBV po = lb_add(p, lb_mul(n, LB_EPS * 10.0));

        /* soft shadows from a 2.5 x 2.5 area light, stratified 2x2, cycled */
        double lit = 0, spec = 0;
        for (s = 0; s < LB_SHADOWS; s++) {
            double jx = ((s & 1) + lb_rnd(rng)) * 0.5;
            double jz = (((s >> 1) & 1) + lb_rnd(rng)) * 0.5;
            LBV lp = lbv(-5.0 + jx * 2.5, 9.0, -4.0 + jz * 2.5);
            LBV ld = lb_sub(lp, po);
            double dist = sqrt(lb_dot(ld, ld));
            ld = lb_mul(ld, 1.0 / dist);
            double ndl = lb_dot(n, ld);
            if (ndl > 0) {
                double tt;
                int ii;
                (*rays)++;
                if (!lb_hit(po, ld, dist, &tt, &ii)) {
                    LBV hv = lb_norm(lb_sub(ld, rd));
                    double sd = lb_dot(n, hv);
                    lit += ndl;
                    if (sd > 0) spec += pow(sd, 48.0);
                }
            }
        }
        lit /= LB_SHADOWS;
        spec /= LB_SHADOWS;

        LBV local = lb_add(lb_mul(base, 0.10 + 0.90 * lit), lb_mul(lbv(1, 1, 1), spec * 0.6));
        acc = lb_add(acc, lb_mulv(thr, lb_mul(local, 1.0 - refl)));
        if (refl <= 0) break;

        thr = lb_mul(lb_mulv(thr, lb_add(lb_mul(base, 0.5), lbv(0.5, 0.5, 0.5))), refl);
        rd = lb_sub(rd, lb_mul(n, 2.0 * lb_dot(rd, n)));
        ro = po;
    }
    return acc;
}

static LBINL uint32_t lb_chan(double v) {
    if (v < 0) v = 0;
    if (v > 1) v = 1;
    return (uint32_t)(pow(v, 1.0 / 2.2) * 255.0 + 0.5);
}

static __attribute__((flatten)) void lb_render_tile(int id, uint64_t *rays) {
    int x0 = (id % LB_TX) * LB_TILE, y0 = (id / LB_TX) * LB_TILE;
    int x1 = x0 + LB_TILE, y1 = y0 + LB_TILE;
    int x, y, sx, sy;
    const double inv = 1.0 / (LB_SPP * LB_SPP);

    if (x1 > LB_W) x1 = LB_W;
    if (y1 > LB_H) y1 = LB_H;

    for (y = y0; y < y1; y++) {
        for (x = x0; x < x1; x++) {
            uint32_t rng = lb_hash((uint32_t)(y * LB_W + x) * 2654435761U + 12345U) | 1U;
            LBV sum = lbv(0, 0, 0);
            for (sy = 0; sy < LB_SPP; sy++) {
                for (sx = 0; sx < LB_SPP; sx++) {
                    double u = (x + (sx + lb_rnd(&rng)) / LB_SPP) / LB_W * 2.0 - 1.0;
                    double v = 1.0 - (y + (sy + lb_rnd(&rng)) / LB_SPP) / LB_H * 2.0;
                    LBV rd = lb_norm(lb_add(lb_add(lb_mul(lb_cu, u * lb_half_w),
                                                   lb_mul(lb_cv, v * lb_half_h)), lb_cw));
                    sum = lb_add(sum, lb_trace(lb_cam, rd, rays, &rng));
                }
            }
            lb_buf[y * LB_W + x] = 0xFF000000U | (lb_chan(sum.x * inv) << 16)
                                 | (lb_chan(sum.y * inv) << 8) | lb_chan(sum.z * inv);
        }
    }
}

static void *lb_worker(void *arg) {
    int me = (int)(intptr_t)arg;
    uint64_t rays = 0;
    for (;;) {
        int t, id;
        if (__atomic_load_n(&lb_stop, __ATOMIC_ACQUIRE)) break;
        t = __atomic_fetch_add(&lb_next, 1, __ATOMIC_ACQ_REL);
        if (t >= LB_NTILES) break;
        id = lb_order[t];
        lb_state[id] = 1;
        lb_render_tile(id, &rays);
        lb_state[id] = 2;
        if (__atomic_add_fetch(&lb_done_n, 1, __ATOMIC_ACQ_REL) == LB_NTILES) lb_t1 = lb_now();
    }
    lb_cnt[me].rays = rays;
    return 0;
}

/* ================= API called from QB64 ================= */

/* buf = _MEM offset of a 960x540 32-bit image. Returns threads started (0 = fail). */
int lb_start(long long buf, int threads) {
    int i;
    if (lb_active) return 0;
    if (!lb_ready) lb_setup();
    if (threads < 1) threads = 1;
    if (threads > LB_MAXT) threads = LB_MAXT;

    lb_buf = (uint32_t *)(intptr_t)buf;
    for (i = 0; i < LB_NTILES; i++) lb_state[i] = 0;
    for (i = 0; i < LB_MAXT; i++) lb_cnt[i].rays = 0;
    lb_next = 0; lb_done_n = 0; lb_stop = 0; lb_t1 = 0;
    lb_t0 = lb_now();

    lb_nth = 0;
    for (i = 0; i < threads; i++) {
        if (pthread_create(&lb_th[i], 0, lb_worker, (void *)(intptr_t)i) != 0) break;
        lb_nth++;
    }
    if (lb_nth == 0) {
        __atomic_store_n(&lb_stop, 1, __ATOMIC_RELEASE);
        return 0;
    }
    lb_active = 1;
    return lb_nth;
}

/* Joins the workers and returns render seconds. If the run is not
   complete this is an abort: workers stop after their current tile. */
double lb_finish(void) {
    int i;
    if (!lb_active) return lb_last;
    if (__atomic_load_n(&lb_done_n, __ATOMIC_ACQUIRE) < LB_NTILES)
        __atomic_store_n(&lb_stop, 1, __ATOMIC_RELEASE);
    for (i = 0; i < lb_nth; i++) pthread_join(lb_th[i], 0);
    if (lb_t1 == 0) lb_t1 = lb_now();
    lb_active = 0;
    lb_last = lb_t1 - lb_t0;
    return lb_last;
}

int lb_is_done(void) {
    return lb_active && __atomic_load_n(&lb_done_n, __ATOMIC_ACQUIRE) == LB_NTILES;
}
int lb_tiles_done(void) { return __atomic_load_n(&lb_done_n, __ATOMIC_ACQUIRE); }
int lb_tiles_total(void) { return LB_NTILES; }
int lb_tiles_x(void) { return LB_TX; }
int lb_width(void) { return LB_W; }
int lb_height(void) { return LB_H; }
int lb_tile_state(int i) { return (i >= 0 && i < LB_NTILES) ? lb_state[i] : 0; }

double lb_elapsed(void) {
    if (!lb_active) return lb_last;
    return (lb_t1 != 0 ? lb_t1 : lb_now()) - lb_t0;
}

/* total rays traced by the last finished run */
double lb_rays(void) {
    double s = 0;
    int i;
    for (i = 0; i < LB_MAXT; i++) s += (double)lb_cnt[i].rays;
    return s;
}

int lb_cpu_count(void) { return (int)sysconf(_SC_NPROCESSORS_ONLN); }

/* FNV-1a over the finished image - identical at any thread count */
uint32_t lb_checksum(void) {
    uint32_t h = 2166136261U;
    int i;
    if (!lb_buf) return 0;
    for (i = 0; i < LB_W * LB_H; i++) { h ^= lb_buf[i]; h *= 16777619U; }
    return h;
}

/* remove every occurrence of pat from s, in place */
static void lb_strip(char *s, const char *pat) {
    size_t n = strlen(pat);
    char *p;
    while ((p = strstr(s, pat)) != 0) memmove(p, p + n, strlen(p + n) + 1);
}

char *lb_cpu_model(void) {
    FILE *f = fopen("/proc/cpuinfo", "r");
    char line[512];
    strcpy(lb_model, "Unknown CPU");
    if (!f) return lb_model;
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, "model name", 10) == 0) {
            char *p = strchr(line, ':');
            if (p) {
                size_t n;
                p++;
                while (*p == ' ' || *p == '\t') p++;
                strncpy(lb_model, p, sizeof lb_model - 1);
                lb_model[sizeof lb_model - 1] = 0;
                n = strlen(lb_model);
                while (n && (lb_model[n - 1] == '\n' || lb_model[n - 1] == '\r' || lb_model[n - 1] == ' '))
                    lb_model[--n] = 0;
                lb_strip(lb_model, "(R)");
                lb_strip(lb_model, "(TM)");
                lb_strip(lb_model, " CPU");
            }
            break;
        }
    }
    fclose(f);
    return lb_model;
}

/* CPU package temp in C from hwmon (coretemp / k10temp / zenpower), -1 if none */
double lb_cpu_temp(void) {
    FILE *f;
    long v = 0;
    if (!lb_tsearched) {
        int h;
        lb_tsearched = 1;
        lb_tpath[0] = 0;
        for (h = 0; h < 32; h++) {
            char nf[128], nm[64];
            snprintf(nf, sizeof nf, "/sys/class/hwmon/hwmon%d/name", h);
            f = fopen(nf, "r");
            if (!f) continue;
            if (fgets(nm, sizeof nm, f)) {
                nm[strcspn(nm, "\r\n")] = 0;
                if (!strcmp(nm, "coretemp") || !strcmp(nm, "k10temp") || !strcmp(nm, "zenpower")) {
                    snprintf(lb_tpath, sizeof lb_tpath, "/sys/class/hwmon/hwmon%d/temp1_input", h);
                    fclose(f);
                    break;
                }
            }
            fclose(f);
        }
    }
    if (!lb_tpath[0]) return -1;
    f = fopen(lb_tpath, "r");
    if (!f) return -1;
    if (fscanf(f, "%ld", &v) != 1) v = 0;
    fclose(f);
    return v / 1000.0;
}

/* ---------------- system info (v1.2) ---------------- */
static char lb_gov[64], lb_drv[64], lb_host[128];

static void lb_read_line(const char *path, char *out, size_t n) {
    FILE *f = fopen(path, "r");
    out[0] = 0;
    if (!f) return;
    if (fgets(out, (int)n, f)) out[strcspn(out, "\r\n")] = 0;
    fclose(f);
}

/* per-logical-CPU clocks in MHz into out[]; returns count (0 if unknown) */
static int lb_read_mhz_all(double *out, int maxn) {
    int n = lb_cpu_count(), i, got = 0;
    FILE *f;
    char line[256];
    for (i = 0; i < n && got < maxn; i++) {
        char p[96];
        long v;
        snprintf(p, sizeof p, "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_cur_freq", i);
        f = fopen(p, "r");
        if (!f) continue;
        if (fscanf(f, "%ld", &v) == 1 && v > 0) out[got++] = v / 1000.0;
        fclose(f);
    }
    if (got) return got;
    /* no cpufreq (some VMs): fall back to /proc/cpuinfo */
    f = fopen("/proc/cpuinfo", "r");
    if (!f) return 0;
    while (got < maxn && fgets(line, sizeof line, f)) {
        if (strncmp(line, "cpu MHz", 7) == 0) {
            char *q = strchr(line, ':');
            if (q) out[got++] = atof(q + 1);
        }
    }
    fclose(f);
    return got;
}

/* average clock across all logical CPUs in MHz, -1 if unknown */
double lb_cpu_mhz(void) {
    double v[1024], sum = 0;
    int n = lb_read_mhz_all(v, 1024), i;
    if (n == 0) return -1;
    for (i = 0; i < n; i++) sum += v[i];
    return sum / n;
}

/* average of the top n clocks = the cores actually doing the work
   in an n-thread run (idle cores at 1.2 GHz no longer drag it down) */
double lb_cpu_mhz_top(int top) {
    double v[1024], sum = 0;
    int n = lb_read_mhz_all(v, 1024), i, j;
    if (n == 0) return -1;
    if (top < 1) top = 1;
    if (top > n) top = n;
    for (i = 0; i < top; i++) {          /* partial selection sort, descending */
        int best = i;
        for (j = i + 1; j < n; j++) if (v[j] > v[best]) best = j;
        if (best != i) { double t = v[i]; v[i] = v[best]; v[best] = t; }
        sum += v[i];
    }
    return sum / top;
}

char *lb_governor(void) {
    lb_read_line("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor", lb_gov, sizeof lb_gov);
    if (!lb_gov[0]) strcpy(lb_gov, "n/a");
    return lb_gov;
}

char *lb_freq_driver(void) {
    lb_read_line("/sys/devices/system/cpu/cpu0/cpufreq/scaling_driver", lb_drv, sizeof lb_drv);
    if (!lb_drv[0]) strcpy(lb_drv, "n/a");
    return lb_drv;
}

char *lb_hostname(void) {
    if (gethostname(lb_host, sizeof lb_host) != 0) strcpy(lb_host, "unknown");
    lb_host[sizeof lb_host - 1] = 0;
    return lb_host;
}

/* ---------------- one benchmark at a time (v1.4) ----------------
   flock on /tmp/linabench.lock. The kernel drops the lock when the
   process exits or crashes, so a stale file can never block a run.
   Returns 1 = we hold it (re-entrant), 0 = another Linabench has it. */
static int lb_lockfd = -1;

int lb_lock(void) {
    int fd;
    if (lb_lockfd >= 0) return 1;
    fd = open("/tmp/linabench.lock", O_RDONLY | O_CREAT, 0666);
    if (fd < 0) return 1;                 /* can't lock at all: don't block runs */
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) { close(fd); return 0; }
    lb_lockfd = fd;
    return 1;
}

void lb_unlock(void) {
    if (lb_lockfd >= 0) {
        flock(lb_lockfd, LOCK_UN);
        close(lb_lockfd);
        lb_lockfd = -1;
    }
}

#pragma GCC pop_options
#endif

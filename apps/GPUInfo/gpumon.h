/* gpumon.h - multi-GPU NVIDIA stats for QB64-PE (via nvidia-smi)
 *
 * GPUMonRefresh() runs nvidia-smi ONCE and caches every GPU it reports
 * (up to GPUMON_MAX). All getters just read the cache, so call
 * GPUMonRefresh() once per update cycle (about 1/sec - nvidia-smi takes
 * roughly 50-100ms to start).
 *
 * Numeric values that the card/driver doesn't report ("[N/A]",
 * "[Not Supported]") come back as -1.0.
 */
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define GPUMON_MAX      8
#define GPUMON_TEXTLEN  96
#define GPUMON_NFIELDS  15   /* index,name,pstate,driver + 11 numeric */
#define GPUMON_NVALS    11

/* Numeric field order below == the fld index used by GPUMonValue():
   0 util%   1 mem-bus util%   2 VRAM used MB   3 VRAM total MB
   4 temp C  5 power W         6 power limit W  7 gfx clock MHz
   8 max gfx clock MHz         9 mem clock MHz  10 fan %
   11 (special) nvidia-smi GPU index */
#define GPUMON_QUERY "index,name,pstate,driver_version," \
    "utilization.gpu,utilization.memory,memory.used,memory.total," \
    "temperature.gpu,power.draw,power.limit," \
    "clocks.gr,clocks.max.gr,clocks.mem,fan.speed"

typedef struct {
    int index;
    char name[GPUMON_TEXTLEN];
    char pstate[16];
    char driver[32];
    double val[GPUMON_NVALS];
} GpuMonRec;

static GpuMonRec g_gm[GPUMON_MAX];
static int g_gmCount = 0;

static char *gm_trim(char *s) {
    char *e;
    while (*s == ' ' || *s == '\t') s++;
    e = s + strlen(s);
    while (e > s && (e[-1] == ' ' || e[-1] == '\t')) *--e = '\0';
    return s;
}

/* "[N/A]", "[Not Supported]", empty, or junk -> -1.0 */
static double gm_num(const char *s) {
    char *end;
    double v;
    if (*s == '\0' || *s == '[') return -1.0;
    v = strtod(s, &end);
    if (end == s || v != v) return -1.0;
    return v;
}

static void gm_copy(char *dst, const char *src, size_t cap) {
    strncpy(dst, src, cap - 1);
    dst[cap - 1] = '\0';
}

static int gm_parse_line(char *line, GpuMonRec *r) {
    char *f[GPUMON_NFIELDS];
    int n = 0, k;
    char *s;

    line[strcspn(line, "\r\n")] = '\0';
    s = line;
    f[n++] = s;
    while (*s && n < GPUMON_NFIELDS) {
        if (*s == ',') { *s = '\0'; f[n++] = s + 1; }
        s++;
    }
    if (n < GPUMON_NFIELDS) return 0;   /* error text, blank line, etc. */

    for (k = 0; k < GPUMON_NFIELDS; k++) f[k] = gm_trim(f[k]);

    r->index = (int)gm_num(f[0]);
    if (r->index < 0) return 0;
    gm_copy(r->name, f[1], sizeof(r->name));
    gm_copy(r->pstate, f[2], sizeof(r->pstate));
    gm_copy(r->driver, f[3], sizeof(r->driver));
    for (k = 0; k < GPUMON_NVALS; k++) r->val[k] = gm_num(f[4 + k]);
    return 1;
}

/* Returns number of GPUs found (0 = no NVIDIA GPU / nvidia-smi missing) */
int GPUMonRefresh(void) {
    /* PATH first, then absolute path for GUI launches with a stripped PATH */
    const char *candidates[] = { "nvidia-smi", "/usr/bin/nvidia-smi" };
    int c;

    for (c = 0; c < 2; c++) {
        char cmd[512];
        char line[512];
        int n = 0;
        FILE *p;

        snprintf(cmd, sizeof(cmd),
                 "%s --query-gpu=" GPUMON_QUERY
                 " --format=csv,noheader,nounits 2>/dev/null", candidates[c]);
        p = popen(cmd, "r");
        if (!p) continue;
        while (fgets(line, sizeof(line), p)) {
            if (n < GPUMON_MAX && gm_parse_line(line, &g_gm[n])) n++;
        }
        pclose(p);
        if (n > 0) { g_gmCount = n; return n; }
    }
    g_gmCount = 0;
    return 0;
}

int GPUMonCount(void) {
    return g_gmCount;
}

double GPUMonValue(int idx, int fld) {
    if (idx < 0 || idx >= g_gmCount) return -1.0;
    if (fld == 11) return (double)g_gm[idx].index;
    if (fld < 0 || fld >= GPUMON_NVALS) return -1.0;
    return g_gm[idx].val[fld];
}

/* which: 0 = name, 1 = pstate, 2 = driver version.
   Copies a null-terminated string into the caller's buffer (a QB64
   String pre-sized with Space$). */
void GPUMonText(int idx, int which, char *buf, int buflen) {
    const char *src = "";
    if (!buf || buflen <= 0) return;
    if (idx >= 0 && idx < g_gmCount) {
        if (which == 0) src = g_gm[idx].name;
        else if (which == 1) src = g_gm[idx].pstate;
        else if (which == 2) src = g_gm[idx].driver;
    }
    strncpy(buf, src, (size_t)buflen - 1);
    buf[buflen - 1] = '\0';
}

/*======================================================================
  sysmon.h  -  direct system sampling for QB64-PE (Linux)

  Replaces the once-a-second shell + temp-file round trip. Everything
  is read straight from /proc and /sys with fopen / fscanf - no root,
  no processes, no /tmp files.

  SM_Update()        take one sample (call about once per second)
  SM_Load()          total CPU load %, from /proc/stat deltas
                     (first call primes the counters and returns 0)
  SM_Temp()          CPU package temp in C (coretemp / k10temp),
                     highest if several; -999 if no sensor found
  SM_MHz()           average "cpu MHz" across all logical CPUs
  SM_FanCount()      fan inputs found in /sys/class/hwmon this sample
  SM_FanChip(i)      hwmon number of fan i          (i = 1..count)
  SM_FanNum(i)       fan number on that chip (the N in fanN_input)
  SM_FanRPM(i)       current speed in rpm
  SM_ModelLen()      length of the CPU model string
  SM_ModelChar(i)    character code i of the model string (1-based)

  Fans are rescanned every sample, so they appear as soon as a sensor
  driver (e.g. nct6775) loads - no restart needed.
======================================================================*/
#include <stdio.h>
#include <string.h>

#define SM_MAXFAN 16
#define SM_MAXHWMON 32

static double sm_load = 0.0, sm_temp = -999.0, sm_mhz = 0.0;
static long long sm_prevTotal = 0, sm_prevIdle = 0;
static int sm_primed = 0;

static int sm_fanCount = 0;
static int sm_fanChip[SM_MAXFAN], sm_fanNum[SM_MAXFAN];
static long sm_fanRpm[SM_MAXFAN];

static char sm_model[128] = "";

static int sm_readLong(const char *path, long *out)
{
    FILE *f = fopen(path, "r");
    int ok;
    if (!f) return 0;
    ok = (fscanf(f, "%ld", out) == 1);
    fclose(f);
    return ok;
}

static int sm_readWord(const char *path, char *buf, int n)
{
    FILE *f = fopen(path, "r");
    char *nl;
    if (!f) return 0;
    if (!fgets(buf, n, f)) { fclose(f); return 0; }
    fclose(f);
    nl = strchr(buf, '\n');
    if (nl) *nl = 0;
    return 1;
}

static void sm_readStat(void)
{
    FILE *f = fopen("/proc/stat", "r");
    char lbl[16];
    long long u, n, s, id, w, q, sq, st, idle, total;
    int k;
    double v;
    if (!f) return;
    k = fscanf(f, "%15s %lld %lld %lld %lld %lld %lld %lld %lld",
               lbl, &u, &n, &s, &id, &w, &q, &sq, &st);
    fclose(f);
    if (k < 9) return;
    idle = id + w;
    total = u + n + s + id + w + q + sq + st;
    if (sm_primed && total > sm_prevTotal) {
        v = (1.0 - (double)(idle - sm_prevIdle) / (double)(total - sm_prevTotal)) * 100.0;
        if (v < 0.0) v = 0.0;
        if (v > 100.0) v = 100.0;
        sm_load = v;
    }
    sm_prevTotal = total;
    sm_prevIdle = idle;
    sm_primed = 1;
}

static void sm_readHwmon(void)
{
    char path[96], name[32];
    int h, j;
    long v;
    double tmax = -999.0;

    sm_fanCount = 0;
    for (h = 0; h < SM_MAXHWMON; h++) {
        snprintf(path, sizeof path, "/sys/class/hwmon/hwmon%d/name", h);
        if (!sm_readWord(path, name, sizeof name)) continue;

        if (strcmp(name, "coretemp") == 0 || strcmp(name, "k10temp") == 0) {
            snprintf(path, sizeof path, "/sys/class/hwmon/hwmon%d/temp1_input", h);
            if (sm_readLong(path, &v) && v / 1000.0 > tmax) tmax = v / 1000.0;
        }

        for (j = 1; j <= 10 && sm_fanCount < SM_MAXFAN; j++) {
            snprintf(path, sizeof path, "/sys/class/hwmon/hwmon%d/fan%d_input", h, j);
            if (sm_readLong(path, &v)) {
                sm_fanChip[sm_fanCount] = h;
                sm_fanNum[sm_fanCount] = j;
                sm_fanRpm[sm_fanCount] = v;
                sm_fanCount++;
            }
        }
    }
    sm_temp = tmax;
}

static void sm_readCpuinfo(void)
{
    FILE *f = fopen("/proc/cpuinfo", "r");
    char line[256], *c, *nl;
    double sum = 0.0, v;
    int n = 0;
    if (!f) return;
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, "cpu MHz", 7) == 0) {
            c = strchr(line, ':');
            if (c && sscanf(c + 1, "%lf", &v) == 1) { sum += v; n++; }
        } else if (sm_model[0] == 0 && strncmp(line, "model name", 10) == 0) {
            c = strchr(line, ':');
            if (c) {
                c++;
                while (*c == ' ' || *c == '\t') c++;
                strncpy(sm_model, c, sizeof sm_model - 1);
                sm_model[sizeof sm_model - 1] = 0;
                nl = strchr(sm_model, '\n');
                if (nl) *nl = 0;
            }
        }
    }
    fclose(f);
    sm_mhz = n ? sum / n : 0.0;
}

/* ---------------- exported to QB64 ---------------- */

void SM_Update(void)
{
    sm_readStat();
    sm_readHwmon();
    sm_readCpuinfo();
}

double SM_Load(void) { return sm_load; }
double SM_Temp(void) { return sm_temp; }
double SM_MHz(void)  { return sm_mhz; }

int SM_FanCount(void) { return sm_fanCount; }

int SM_FanChip(int i)
{
    return (i >= 1 && i <= sm_fanCount) ? sm_fanChip[i - 1] : -1;
}

int SM_FanNum(int i)
{
    return (i >= 1 && i <= sm_fanCount) ? sm_fanNum[i - 1] : 0;
}

int SM_FanRPM(int i)
{
    return (i >= 1 && i <= sm_fanCount) ? (int)sm_fanRpm[i - 1] : 0;
}

int SM_ModelLen(void) { return (int)strlen(sm_model); }

int SM_ModelChar(int i)
{
    int n = (int)strlen(sm_model);
    return (i >= 1 && i <= n) ? (unsigned char)sm_model[i - 1] : 0;
}

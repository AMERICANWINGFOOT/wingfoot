/*
 * pmmount.c  -  mount control for PoleMasterQB v2 (QB64-PE front end)
 *
 *   Sky-Watcher / Orion SynScan motor protocol over the mount's WiFi
 *   (UDP port 11880) or a USB / EQDIR cable. This is QBCap's mount code
 *   (qbcap.c step 10), the same tested thread, cut down to what polar
 *   alignment needs: connect, tracking on/off, GoTo by axis amounts, stop,
 *   status and messages.
 *
 *   All mount I/O happens on one background thread. It stops both axes
 *   (and turns tracking off) if:
 *     - an axis stalls (its encoder stops counting while it should move),
 *     - the mount stops answering (two missed position reads in a row),
 *     - the mount refuses a move command,
 *     - a GoTo takes longer than 4 minutes,
 *     - pmm_stop() is called (the Stop button / Esc key).
 *
 * All exported functions use int / double / char* so they map onto QB64
 * Long, Double and _Offset.
 *
 * Build:  sh build_pmmount.sh
 *   gcc -O2 -Wall -shared -fPIC -o libpmmount.so pmmount.c -lpthread -lm
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <termios.h>
#include <sys/select.h>

#define PMM_VERSION 2

#define MT_SIDEREAL (360.0 / 86164.0905)
#define MT_KEEPALIVE_S 0.6
#define MT_STALL_MIN_SPEED 0.05      /* deg/s - slower moves are not stall-checked */

static char g_err[256];

static int fail_msg(const char *msg)
{
    snprintf(g_err, sizeof g_err, "%s", msg);
    return -99;
}

static void copy_str(char *dst, int len, const char *src)
{
    if (!dst || len <= 0) return;
    strncpy(dst, src ? src : "", (size_t)len - 1);
    dst[len - 1] = 0;
}

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
    int gotoOn; double gotoTgt[3], gotoT0;   /* GoTo: absolute axis targets (deg) */
    /* actual (thread only, copied out under the lock) */
    int curDir[3]; double curSpeed[3];
    double startT[3], chkPos[3], chkT[3]; int bad[3];
    double pos[3]; int posOk;
    double posT; int glitch;     /* time of the last good reading; impossible jumps in a row */
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
    default:  return 0;        /* G I J K F: just "=" */
    }
}

/* is "in" (n chars, '\r' included or not) a believable answer to command c? */
static int mt_reply_ok(char c, const char *in, int n)
{
    if (n > 0 && in[n - 1] == '\r') n--;
    if (n < 1) return 0;
    if (in[0] == '!') return n == 2;                    /* "!<code>" error */
    if (in[0] != '=' || n - 1 != mt_reply_len(c)) return 0;
    {   /* data answers must be hex digits - a garbled packet is not a position */
        int i;
        for (i = 1; i < n; i++) {
            char h = in[i];
            if (!((h >= '0' && h <= '9') || (h >= 'A' && h <= 'F') || (h >= 'a' && h <= 'f'))) return 0;
        }
    }
    return 1;
}

static char mt_lastErr = 0;     /* error code of the last '!' answer */

/* ":<c><axis><data>\r" -> reply after '=' ; 0 ok, 1 mount error, -1 no answer.
 * Over WiFi a late answer to an earlier command can turn up after a newer
 * command was sent. Answers that have the wrong length for this command are
 * thrown away (QBCap's version took them, which could make a "is the motor
 * still running?" question read a position, and the next start command then
 * hit a running motor: "refused a move command"). */
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
        }
        if (n > 0 && (in[0] == '=' || in[0] == '!')) break;
        n = 0;
    }
    if (n <= 0) return -1;
    in[n] = 0;
    if (in[n - 1] == '\r') in[--n] = 0;
    if (reply && len > 0) snprintf(reply, len, "%s", in + 1);
    if (in[0] == '!') mt_lastErr = in[1];
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
    mt_lastErr = 0;
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

static void mt_all_stop_wants(void)
{
    pthread_mutex_lock(&mt.mx);
    mt.wantDir[1] = mt.wantDir[2] = 0; mt.trackOn = 0; mt.gotoOn = 0;
    pthread_mutex_unlock(&mt.mx);
}

/* GoTo speed profile: distance to go (deg) -> speed (deg/s); 0 = arrived.
 * The alignment steps are short, so they run at 1 deg/s at most (gentle on
 * a loaded mount); only the long slew back to the start goes 2 deg/s. */
static double mt_goto_speed(double err)
{
    err = fabs(err);
    if (err > 10.0) return 2.0;
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
        double ws[3];
        pthread_mutex_lock(&mt.mx);
        for (a = 1; a <= 2; a++) {
            if (mt.wantDir[a] && now - mt.keepT[a] > MT_KEEPALIVE_S) mt.wantDir[a] = 0;
            wd[a] = mt.wantDir[a]; ws[a] = mt.wantSpeed[a];
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
                    mt_all_stop_wants();
                    mt_say("GoTo took too long - stopped.");
                } else {
                    wd[1] = s1 > 0 ? (e1 > 0 ? 1 : -1) : 0; ws[1] = s1;
                    wd[2] = s2 > 0 ? (e2 > 0 ? 1 : -1) : 0; ws[2] = s2;
                    tr = 0;
                }
            }
        }

        /* positions every 0.25 s (faster during a GoTo) */
        if (now - lastPosT >= (mt.gotoOn ? 0.12 : 0.25)) {
            double p1 = mt_read_pos(1), p2 = isnan(p1) ? NAN : mt_read_pos(2);
            /* RA read a second time: over WiFi the answers can slip one command
             * behind (RA's question gets Dec's answer and so on) - then the two
             * RA readings disagree and this poll is thrown away */
            double p1b = isnan(p2) ? NAN : mt_read_pos(1);
            int mixed = !isnan(p1b) && fabs(p1b - p1) > 0.6;   /* 2 deg/s slews move < 0.6 deg between the two */
            lastPosT = now;
            if (isnan(p1) || isnan(p2) || isnan(p1b)) {
                if (++mt.lost == 2) {
                    mt_all_stop_wants();
                    mt_say("LOST CONTACT with the mount - sent STOP, tracking off. Check the mount and its WiFi.");
                    mt.curDir[1] = mt.curDir[2] = 0; mt.curSpeed[1] = mt.curSpeed[2] = 0;
                }
                /* keep sending STOP while the link is down - one STOP can be lost
                 * too, and a SynScan motor keeps turning until it hears one */
                if (mt.lost >= 2) { mt_cmd('K', 1, NULL, NULL, 0); mt_cmd('K', 2, NULL, NULL, 0); }
            } else if (mixed) {
                /* answers out of step: ignore this poll */
            } else {
                if (mt.lost >= 2) {
                    /* back in contact: make sure both motors really are stopped
                     * before anything else happens */
                    mt_stop_axis(1, 1); mt_stop_axis(2, 1);
                }
                /* the axes cannot move faster than 2 deg/s: a reading that jumped
                 * further is a mixed-up answer on the WiFi link - ignore it, unless
                 * it keeps saying so (then the mount really is somewhere else).
                 * After a lost link the gap since the last good reading is long, so
                 * that gap is capped (the mount was sent STOP), and a jumped reading
                 * is only believed when 5 readings in a row agree WITH EACH OTHER -
                 * on 2026-10-13, after a WiFi drop, it read RA 117 / Dec 42.7 although
                 * the run never moves Dec, and Go to HOME then drove the Dec axis. */
                double gap = now - mt.posT;
                double lim, clim;
                int jump;
                if (gap > 2.0) gap = 2.0;
                lim = 2.5 * gap + 0.3;
                jump = mt.posOk && (fabs(p1 - mt.pos[1]) > lim || fabs(p2 - mt.pos[2]) > lim);
                if (mt.lost >= 2) mt_say("Mount answering again (tracking is off - turn it back on if wanted).");
                mt.lost = 0;
                if (jump) {
                    clim = 2.5 * (now - mt.candT) + 0.3;
                    if (mt.glitch > 0 && fabs(p1 - mt.cand[1]) <= clim && fabs(p2 - mt.cand[2]) <= clim)
                        mt.glitch++;                          /* agrees with the last odd one */
                    else
                        mt.glitch = 1;                        /* a new odd reading: start counting */
                    mt.cand[1] = p1; mt.cand[2] = p2; mt.candT = now;
                }
                if (jump && mt.glitch < 5) {
                    /* skip this reading */
                } else {
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
            else if (a == 1 && tr) { dir = 1; sp = MT_SIDEREAL; }
            if (dir == mt.curDir[a] && fabs(sp - mt.curSpeed[a]) < 1e-9) continue;
            if (mt.curDir[a] != 0) mt_stop_axis(a, 1);
            if (dir != 0 && mt_start_axis(a, sp, dir) != 0) {
                /* usually "motor not stopped yet": make sure it is stopped, try once more */
                mt_stop_axis(a, 1);
                usleep(150000);
                if (mt_start_axis(a, sp, dir) != 0) {
                    char m[160];
                    mt_stop_axis(a, 0);
                    mt_all_stop_wants();
                    snprintf(m, sizeof m, "The mount refused a move command twice (%s error %c%s) - stopped.",
                             a == 1 ? "RA" : "Dec", mt_lastErr ? mt_lastErr : '-',
                             mt_lastErr == '2' ? ": motor not stopped" : mt_lastErr == '5' ? ": motor asleep" : mt_lastErr ? "" : ": no answer");
                    mt_say(m);
                } else {
                    mt_say("Mount needed a second try for a move (weak link) - carrying on.");
                }
            }
        }

        /* stall watchdog: the axis encoders must keep counting */
        for (a = 1; a <= 2; a++) {
            double dt, moved, want;
            if (!mt.curDir[a] || mt.curSpeed[a] < MT_STALL_MIN_SPEED || !mt.posOk) continue;
            if (mt.lost) { mt.chkT[a] = now; mt.chkPos[a] = mt.pos[a]; continue; }
            dt = now - mt.chkT[a];
            if (dt < 0.5) continue;
            moved = fabs(mt.pos[a] - mt.chkPos[a]);
            want = mt.curSpeed[a] * dt;
            if (now - mt.startT[a] > 2.0 && moved < 0.25 * want) mt.bad[a]++; else mt.bad[a] = 0;
            mt.chkPos[a] = mt.pos[a]; mt.chkT[a] = now;
            if (mt.bad[a] >= 2) {
                char s[160];
                mt_stop_axis(1, 0); mt_stop_axis(2, 0);
                mt_all_stop_wants();
                snprintf(s, sizeof s, "%s axis STALLED (moved %.2f deg, expected %.2f) - both axes stopped, tracking off. Check for a snag.",
                         a == 1 ? "RA" : "Dec", moved, want);
                mt_say(s);
            }
        }
        usleep(50000);
    }
    return NULL;
}

int pmm_version(void) { return PMM_VERSION; }

int pmm_last_error(char *buf, int len) { copy_str(buf, len, g_err); return 0; }

/* addr: "192.168.4.1" (WiFi, UDP 11880) or "/dev/ttyUSB0" (USB, 115200; ",9600" for EQDIR).
 * Returns 0 ok, -99 error (pmm_last_error). Connecting stops both axes. */
int pmm_open(const char *addr)
{
    char r[64], dev[256];
    int a, baud = 115200;
    const char *comma;
    if (mt.open) return 0;
    memset(mt.wantDir, 0, sizeof mt.wantDir); mt.trackOn = 0; mt.lost = 0; mt.posOk = 0; mt.gotoOn = 0;
    memset(mt.curDir, 0, sizeof mt.curDir); memset(mt.curSpeed, 0, sizeof mt.curSpeed);
    if (!addr || !*addr) addr = "192.168.4.1";
    if (addr[0] == '/') {
        struct termios t;
        comma = strchr(addr, ',');
        snprintf(dev, sizeof dev, "%.*s", comma ? (int)(comma - addr) : (int)strlen(addr), addr);
        if (comma) baud = atoi(comma + 1);
        mt.fd = open(dev, O_RDWR | O_NOCTTY);
        if (mt.fd < 0) { snprintf(g_err, sizeof g_err, "mount: cannot open %.100s (%.80s)", dev, strerror(errno)); return -99; }
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
            return fail_msg(mt.isUdp ? "mount: no answer - is this computer on the mount's WiFi (SynScan app and QBCap mount closed)?"
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
    mt.posT = mt_now(); mt.glitch = 0;
    mt.quit = 0;
    if (pthread_create(&mt.thr, NULL, mt_thread, NULL) != 0) { close(mt.fd); mt.fd = -1; return fail_msg("mount: no thread"); }
    mt.open = 1;
    mt.msg[0] = 0;
    return 0;
}

void pmm_close(void)
{
    if (!mt.open) return;
    mt_all_stop_wants();
    usleep(150000);
    mt.quit = 1;
    pthread_join(mt.thr, NULL);
    mt_cmd('K', 1, NULL, NULL, 0);
    mt_cmd('K', 2, NULL, NULL, 0);
    close(mt.fd); mt.fd = -1;
    mt.open = 0;
}

int pmm_is_open(void) { return mt.open; }

int pmm_track(int onFlag)
{
    if (!mt.open) return -1;
    pthread_mutex_lock(&mt.mx);
    mt.trackOn = onFlag ? 1 : 0;
    pthread_mutex_unlock(&mt.mx);
    return 0;
}

/* stops both axes, cancels any GoTo, tracking off */
int pmm_stop(void)
{
    if (!mt.open) return -1;
    mt_all_stop_wants();
    return 0;
}

/* returns 1 = connected, 0 = not open, -1 = no answer from the mount.
 * axis angles in degrees (counted from where the mount was at power-up);
 * state: 0 stopped, 1 moving, 2 tracking, 3 GoTo running. */
int pmm_status(double *raDeg, double *decDeg, int *raState, int *decState, int *tracking)
{
    if (!mt.open) return 0;
    pthread_mutex_lock(&mt.mx);
    if (raDeg) *raDeg = mt.pos[1];
    if (decDeg) *decDeg = mt.pos[2];
    if (raState) *raState = mt.gotoOn ? 3 : mt.curDir[1] == 0 ? 0 : (mt.trackOn && mt.curSpeed[1] < 1.5 * MT_SIDEREAL) ? 2 : 1;
    if (decState) *decState = mt.gotoOn ? 3 : mt.curDir[2] ? 1 : 0;
    if (tracking) *tracking = mt.trackOn;
    pthread_mutex_unlock(&mt.mx);
    return mt.lost >= 2 ? -1 : 1;
}

/* newest notable message (GoTo done, stall, lost link...). Returns its sequence number. */
int pmm_message(char *buf, int len)
{
    int s;
    pthread_mutex_lock(&mt.mx);
    copy_str(buf, len, mt.msg);
    s = mt.msgSeq;
    pthread_mutex_unlock(&mt.mx);
    return s;
}

int pmm_info(char *buf, int len) { copy_str(buf, len, mt.open ? mt.info : ""); return mt.open ? 0 : -1; }

/* GoTo by axis amounts (degrees, + = forward / west for RA). Refuses moves
 * over 90 deg. A stall, a lost link or pmm_stop cancels it. Tracking (if on)
 * carries on when it is done. */
int pmm_goto_axes(double dRA, double dDec)
{
    if (!mt.open) return fail_msg("mount not connected");
    if (fabs(dRA) > 90 || fabs(dDec) > 90) return fail_msg("GoTo move too large");
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

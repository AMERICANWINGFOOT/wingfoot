/*
 * mountjog.c  -  move a Sky-Watcher / Orion SynScan mount from the keyboard
 *                (motor protocol, WiFi or USB). For Russell's Atlas Pro AZ/EQ-G.
 *
 *   ./mountjog                   WiFi, mount at 192.168.4.1 (UDP 11880)
 *   ./mountjog /dev/ttyUSB0      USB (115200 baud; add 9600 for an EQDIR cable)
 *
 * Keys:  arrows  move  (left/right = axis 1 RA, up/down = axis 2 Dec)
 *        1..6    speed: 1x, 8x, 32x sidereal, 0.5, 1, 2 deg/s
 *        SPACE   STOP both axes          t  RA sidereal tracking on
 *        p       show positions          q  stop everything and quit
 *
 * Safety: every move stops by itself after 10 s unless its key is pressed
 * again; top speed 2 deg/s; quitting (q, Ctrl-C, closing the terminal)
 * stops both axes first. If the computer loses the mount's WiFi, the mount
 * keeps doing what it was doing - be ready at the power switch.
 *
 * Build:  gcc -O2 -Wall -o mountjog mountjog.c -lm
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <math.h>
#include <time.h>
#include <termios.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/select.h>

#define AUTO_STOP_S   10.0
#define MAX_DEG_S     2.0
#define SIDEREAL_DEG_S (360.0 / 86164.0905)
#define FENCE_DEG     60.0   /* each axis stays within this of where it was at start */
#define STALL_CHECK_S 0.5

static int fd = -1, isUdp = 0;
static struct sockaddr_in mount;
static struct termios oldTerm;
static int termSaved = 0;
static long cpr[3], tmrFreq[3], hsRatio[3];
static double startPos[3], startT[3];
static int tracked[3];
static double curSpeed[3], homePos[3], lastChkPos[3], lastChkT[3];
static int badCount[3], watchOn = 1;
static FILE *jogLog;

/* ---- link ------------------------------------------------------------ */
static int open_udp(const char *ip)
{
    struct timeval tv = { 0, 500000 };
    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    memset(&mount, 0, sizeof mount);
    mount.sin_family = AF_INET;
    mount.sin_port = htons(11880);
    if (inet_pton(AF_INET, ip, &mount.sin_addr) != 1) return -1;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    isUdp = 1;
    return 0;
}

static int open_serial(const char *dev, int baud)
{
    struct termios t;
    fd = open(dev, O_RDWR | O_NOCTTY);
    if (fd < 0) return -1;
    tcgetattr(fd, &t);
    cfmakeraw(&t);
    cfsetispeed(&t, baud == 9600 ? B9600 : B115200);
    cfsetospeed(&t, baud == 9600 ? B9600 : B115200);
    t.c_cflag |= CLOCAL | CREAD;
    t.c_cc[VMIN] = 0; t.c_cc[VTIME] = 5;
    tcsetattr(fd, TCSANOW, &t);
    tcflush(fd, TCIOFLUSH);
    return 0;
}

/* ":<cmd><axis><data>\r" -> reply data after '='. 0 ok, 1 mount error, -1 no answer */
static int cmd(char c, int axis, const char *data, char *reply, int len)
{
    char out[24], in[64];
    int n = 0, tries;
    snprintf(out, sizeof out, ":%c%c%s\r", c, (char)('0' + axis), data ? data : "");
    for (tries = 0; tries < 4; tries++) {
        if (isUdp) {
            /* drop any stale datagram first (late answer to an earlier try) */
            char junk[64];
            while (recvfrom(fd, junk, sizeof junk, MSG_DONTWAIT, NULL, NULL) > 0) ;
            if (sendto(fd, out, strlen(out), 0, (struct sockaddr *)&mount, sizeof mount) < 0) return -1;
            n = recvfrom(fd, in, sizeof in - 1, 0, NULL, NULL);
        } else {
            int got;
            tcflush(fd, TCIFLUSH);
            if (write(fd, out, strlen(out)) < 0) return -1;
            n = 0;
            while (n < (int)sizeof in - 1 && (got = read(fd, in + n, 1)) == 1) if (in[n++] == '\r') break;
        }
        if (n > 0 && (in[0] == '=' || in[0] == '!')) break;
        n = 0;
    }
    if (n <= 0) return -1;
    in[n] = 0;
    if (in[n - 1] == '\r') in[--n] = 0;
    if (reply) snprintf(reply, len, "%s", in + 1);
    return in[0] == '=' ? 0 : 1;
}

static long hex24(const char *s)
{
    char b[3] = { 0, 0, 0 };
    long v = 0;
    int i, n = (int)strlen(s) / 2;
    for (i = n - 1; i >= 0; i--) { b[0] = s[2 * i]; b[1] = s[2 * i + 1]; v = (v << 8) | strtol(b, NULL, 16); }
    return v;
}

static void le24(long v, char *out)
{
    sprintf(out, "%02lX%02lX%02lX", v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF);
}

/* ---- motor control ---------------------------------------------------- */
static double now_s(void);
static double pos_deg(int a);
static int axis_running(int a)
{
    char r[64];
    if (cmd('f', a, NULL, r, sizeof r) != 0 || strlen(r) < 3) return -1;
    return (strtol((char[]){ r[1], 0 }, NULL, 16) & 1) ? 1 : 0;
}

static void stop_axis(int a, int wait)
{
    int i;
    cmd('K', a, NULL, NULL, 0);                  /* decelerate to a stop */
    for (i = 0; wait && i < 60; i++) {           /* up to ~6 s */
        if (axis_running(a) == 0) return;
        usleep(100000);
    }
}

static void stop_all(void)
{
    if (fd < 0) return;
    cmd('K', 1, NULL, NULL, 0);
    cmd('K', 2, NULL, NULL, 0);
}

/* move axis a at speed degPerSec, dir +1/-1 (0 = stop) */
static int move_axis(int a, double degPerSec, int dir)
{
    char data[8], r[64];
    int high;
    double t1;
    long period;
    stop_axis(a, 1);
    if (dir == 0 || degPerSec <= 0) return 0;
    if (degPerSec > MAX_DEG_S) degPerSec = MAX_DEG_S;
    /* timer ticks per motor step: T1 = TimerFreq * 360 / speed / CPR (high speed: x ratio) */
    t1 = (double)tmrFreq[a] * 360.0 / degPerSec / (double)cpr[a];
    /* slow mode only while its period is long enough to be accurate (and never under
       the minimum of 6); otherwise high-speed mode with the period x ratio */
    high = degPerSec > 128.0 * SIDEREAL_DEG_S || t1 < 10.0;
    if (high) t1 *= (double)hsRatio[a];
    period = (long)(t1 + 0.5);
    if (period < 6) period = 6;                 /* never ask for an absurd rate */
    /* mode digit: 1 = slow (tracking) speed, 3 = high speed; direction digit: 0 forward, 1 back */
    snprintf(data, sizeof data, "%c%c", high ? '3' : '1', dir > 0 ? '0' : '1');
    if (cmd('G', a, data, r, sizeof r) != 0) { printf("\n  mode refused (%s)\n", r); return -1; }
    le24(period, data);
    if (cmd('I', a, data, r, sizeof r) != 0) { printf("\n  speed refused (%s)\n", r); return -1; }
    startPos[a] = pos_deg(a); startT[a] = now_s();
    curSpeed[a] = degPerSec; lastChkPos[a] = startPos[a]; lastChkT[a] = startT[a]; badCount[a] = 0;
    if (jogLog) fprintf(jogLog, "%.2f START axis %d %s %.4f deg/s period %ld from %.4f\n", startT[a], a, dir > 0 ? "+" : "-", degPerSec, period, startPos[a]);
    if (cmd('J', a, NULL, r, sizeof r) != 0) { printf("\n  start refused (%s)\n", r); return -1; }
    tracked[a] = !isnan(startPos[a]);
    return 0;
}

static double pos_deg(int a)
{
    char r[64];
    if (cmd('j', a, NULL, r, sizeof r) != 0) return NAN;
    return (double)(hex24(r) - 0x800000) * 360.0 / (double)cpr[a];
}

/* ---- terminal ----------------------------------------------------------- */
static void restore_term(void) { if (termSaved) tcsetattr(0, TCSANOW, &oldTerm); }

static void on_signal(int s)
{
    stop_all();
    restore_term();
    fprintf(stderr, "\nStopped both axes (signal %d).\n", s);
    _exit(1);
}

static double now_s(void);
static double pos_deg(int a);

/* after a move has stopped: how far did it really go, and how fast */
static void report(int a)
{
    double p, dt;
    if (!tracked[a]) return;
    tracked[a] = 0;
    usleep(300000);                               /* let the slow-down finish */
    p = pos_deg(a); dt = now_s() - startT[a];
    if (isnan(p) || dt <= 0) return;
    printf("  axis %d moved %+.3f deg in %.1f s = %.3f deg/s average (now at %.4f)\n",
           a, p - startPos[a], dt, fabs(p - startPos[a]) / dt, p);
}

static double now_s(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }

/* returns key code: 'U','D','L','R' for arrows, else the char; 0 = none within timeout */
static int get_key(int ms)
{
    fd_set s;
    struct timeval tv = { ms / 1000, (ms % 1000) * 1000 };
    unsigned char c;
    FD_ZERO(&s); FD_SET(0, &s);
    if (select(1, &s, NULL, NULL, &tv) <= 0) return 0;
    if (read(0, &c, 1) != 1) return 0;
    if (c == 27) {
        unsigned char seq[2];
        if (read(0, &seq[0], 1) == 1 && read(0, &seq[1], 1) == 1 && seq[0] == '[') {
            switch (seq[1]) { case 'A': return 'U'; case 'B': return 'D'; case 'C': return 'R'; case 'D': return 'L'; }
        }
        return 0;
    }
    return c;
}

int main(int argc, char **argv)
{
    static const double speeds[6] = { SIDEREAL_DEG_S, 8 * SIDEREAL_DEG_S, 32 * SIDEREAL_DEG_S, 0.5, 1.0, 2.0 };
    static const char *speedName[6] = { "1x sidereal", "8x", "32x", "0.5 deg/s", "1 deg/s", "2 deg/s" };
    const char *target = argc > 1 ? argv[1] : "192.168.4.1";
    char r[64];
    int a, sp = 2, moving[3] = { 0, 0, 0 };
    double moveEnd[3] = { 0, 0, 0 };
    struct termios t;

    if (target[0] == '/') { if (open_serial(target, argc > 2 ? atoi(argv[2]) : 115200) != 0) { perror(target); return 1; } }
    else if (open_udp(target) != 0) { fprintf(stderr, "bad address %s\n", target); return 1; }

    signal(SIGINT, on_signal); signal(SIGTERM, on_signal); signal(SIGHUP, on_signal);
    for (a = 1; a <= 2; a++) {
        if (cmd('a', a, NULL, r, sizeof r) != 0) { fprintf(stderr, "No answer from the mount (joined its WiFi? SynScan app closed?)\n"); return 2; }
        cpr[a] = hex24(r);
        if (cmd('b', a, NULL, r, sizeof r) == 0) tmrFreq[a] = hex24(r);
        hsRatio[a] = 16;
        if (cmd('g', a, NULL, r, sizeof r) == 0 && hex24(r) > 0) hsRatio[a] = hex24(r);
        if (cpr[a] <= 0 || tmrFreq[a] <= 0) { fprintf(stderr, "Odd answers from axis %d - not moving anything.\n", a); return 3; }
    }
    /* initialise the motor board (as SynScan does on connect); positions stay as they are */
    cmd('F', 1, NULL, NULL, 0);
    cmd('F', 2, NULL, NULL, 0);
    stop_all();

    homePos[1] = pos_deg(1); homePos[2] = pos_deg(2);
    if (isnan(homePos[1]) || isnan(homePos[2])) { fprintf(stderr, "Cannot read positions - not moving anything.\n"); return 3; }
    printf("Mount ready: %ld steps/turn, timer %ld Hz, high-speed ratio %ld\n", cpr[1], tmrFreq[1], hsRatio[1]);
    printf("arrows = move   1-6 = speed   SPACE = STOP   t = track RA   p = position   q = quit\n");
    printf("Every move stops by itself after %.0f s. Speed: %s\n", AUTO_STOP_S, speedName[sp]);
    printf("Safety: a move stops if the axis stalls, or goes more than %.0f deg from where it is now.\n", FENCE_DEG);

    jogLog = fopen("mountjog.log", "a");
    if (jogLog) { time_t tt = time(NULL); fprintf(jogLog, "---- mountjog %s", ctime(&tt)); fflush(jogLog); }
    printf("w = stall stop on/off. Each move is logged to mountjog.log\n");
    tcgetattr(0, &oldTerm); termSaved = 1;
    t = oldTerm; t.c_lflag &= ~(ICANON | ECHO); tcsetattr(0, TCSANOW, &t);
    atexit(restore_term);

    for (;;) {
        int k = get_key(100), ax = 0, dir = 0;
        double tnow = now_s();
        for (a = 1; a <= 2; a++)
            if (moving[a] && moving[a] != 9 && tnow > moveEnd[a]) {
                printf("  axis %d auto-stop\n", a);
                stop_axis(a, 1); moving[a] = 0; report(a);
            }
        /* stall + fence watchdog */
        for (a = 1; a <= 2; a++) {
            double p, dt, want;
            if (!moving[a] || tnow - lastChkT[a] < STALL_CHECK_S) continue;
            p = pos_deg(a); dt = tnow - lastChkT[a];
            if (isnan(p)) { stop_all(); moving[1] = moving[2] = 0; printf("  LOST CONTACT with the mount - sent STOP. Check it now!\n"); continue; }
            want = curSpeed[a] * dt;
            if (jogLog) {
                char st[64] = "?";
                cmd('f', a, NULL, st, sizeof st);
                fprintf(jogLog, "%.2f axis %d pos %.4f moved %.4f in %.2f s (expected %.4f) status %s\n",
                        tnow, a, p, p - lastChkPos[a], dt, want, st);
                fflush(jogLog);
            }
            if (tnow - startT[a] > 2.0 && fabs(p - lastChkPos[a]) < 0.25 * want) badCount[a]++; else badCount[a] = 0;
            if (watchOn && badCount[a] >= 2) {
                stop_all(); moving[1] = moving[2] = 0;
                printf("\a  *** axis %d STALLED (moved %.3f deg, expected %.3f) - both axes stopped ***\n", a, fabs(p - lastChkPos[a]), want);
                if (jogLog) fprintf(jogLog, "%.2f STALL STOP axis %d\n", tnow, a);
                tracked[1] = tracked[2] = 0;
                continue;
            }
            if (!watchOn && badCount[a] == 2) printf("  (axis %d looks stalled - stall stop is OFF)\n", a);
            if (fabs(p - homePos[a]) > FENCE_DEG) {
                stop_all(); moving[1] = moving[2] = 0;
                printf("\a  axis %d reached the %.0f deg fence - stopped. Restart mountjog to set a new centre.\n", a, FENCE_DEG);
                report(1); report(2);
                continue;
            }
            lastChkPos[a] = p; lastChkT[a] = tnow;
        }
        if (!k) continue;
        switch (k) {
            case 'L': ax = 1; dir = -1; break;
            case 'R': ax = 1; dir = +1; break;
            case 'U': ax = 2; dir = +1; break;
            case 'D': ax = 2; dir = -1; break;
            case ' ':
                stop_all(); moving[1] = moving[2] = 0;
                printf("  STOP\n");
                stop_axis(1, 1); stop_axis(2, 1); report(1); report(2); break;
            case 'w':
                watchOn = !watchOn;
                printf(watchOn ? "  stall stop ON\n" : "  stall stop OFF - watch the mount, SPACE stops\n");
                if (jogLog) fprintf(jogLog, "%.2f stall stop %s\n", tnow, watchOn ? "ON" : "OFF");
                break;
            case 't':
                if (move_axis(1, SIDEREAL_DEG_S, +1) == 0) { moving[1] = 9; printf("  RA tracking at sidereal rate (SPACE stops it)\n"); }
                break;
            case 'p':
                printf("  axis 1 %.4f deg   axis 2 %.4f deg\n", pos_deg(1), pos_deg(2)); break;
            case 'q': case 'Q':
                stop_all(); stop_axis(1, 1); stop_axis(2, 1);
                printf("Stopped both axes. Bye.\n");
                return 0;
            default:
                if (k >= '1' && k <= '6') { sp = k - '1'; printf("  speed %s\n", speedName[sp]); }
        }
        if (ax) {
            if (moving[ax] == dir) { moveEnd[ax] = tnow + AUTO_STOP_S; continue; }
            { double p = pos_deg(ax);
              if (!isnan(p) && (p - homePos[ax]) * dir > FENCE_DEG - 0.5) { printf("  axis %d is at the fence - that way is blocked\n", ax); continue; } }
            if (move_axis(ax, speeds[sp], dir) == 0) {
                moving[ax] = dir; moveEnd[ax] = tnow + AUTO_STOP_S;
                printf("  axis %d %s at %s\n", ax, dir > 0 ? "+" : "-", speedName[sp]);
            }
        }
    }
}

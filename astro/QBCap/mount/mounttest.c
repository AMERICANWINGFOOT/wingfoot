/*
 * mounttest.c  -  READ-ONLY test of a Sky-Watcher mount (SynScan motor protocol).
 * It never moves the mount: it only asks questions.
 *
 *   WiFi :  ./mounttest                    (default 192.168.4.1, UDP port 11880)
 *           ./mounttest 192.168.4.1
 *   USB  :  ./mounttest /dev/ttyUSB0       (mount's own USB port: 115200 baud)
 *           ./mounttest /dev/ttyUSB0 9600  (EQDIR cable on older mounts)
 *
 * Build:   gcc -O2 -Wall -o mounttest mounttest.c
 *
 * Protocol: ":" + command + axis ('1' = RA/azimuth, '2' = Dec/altitude) + "\r".
 * Reply "=" + data + "\r" (ok) or "!" + code + "\r" (error). Numbers are
 * 24-bit hex sent low byte first ("563412" means 0x123456).
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <termios.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/select.h>
#include <sys/time.h>

static int fd = -1, isUdp = 0;
static char lastRaw[64];   /* exact last reply, for diagnosis */
static struct sockaddr_in mount;

static int open_udp(const char *ip)
{
    struct timeval tv = { 1, 0 };
    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) { perror("socket"); return -1; }
    memset(&mount, 0, sizeof mount);
    mount.sin_family = AF_INET;
    mount.sin_port = htons(11880);
    if (inet_pton(AF_INET, ip, &mount.sin_addr) != 1) { fprintf(stderr, "bad IP address %s\n", ip); return -1; }
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    isUdp = 1;
    return 0;
}

static int open_serial(const char *dev, int baud)
{
    struct termios t;
    speed_t sp = baud == 9600 ? B9600 : baud == 19200 ? B19200 : baud == 38400 ? B38400 : B115200;
    fd = open(dev, O_RDWR | O_NOCTTY);
    if (fd < 0) { fprintf(stderr, "cannot open %s: %s\n", dev, strerror(errno)); return -1; }
    tcgetattr(fd, &t);
    cfmakeraw(&t);
    cfsetispeed(&t, sp); cfsetospeed(&t, sp);
    t.c_cflag |= CLOCAL | CREAD;
    t.c_cc[VMIN] = 0; t.c_cc[VTIME] = 10;       /* 1 s read timeout */
    tcsetattr(fd, TCSANOW, &t);
    tcflush(fd, TCIOFLUSH);
    return 0;
}

/* send ":<cmd><axis>\r", get the reply between '=' and '\r'. Returns 0 ok, 1 mount error, -1 no answer */
static int ask(char cmd, char axis, char *reply, int len)
{
    char out[8], in[64];
    int n = 0, tries;
    snprintf(out, sizeof out, ":%c%c\r", cmd, axis);
    for (tries = 0; tries < 3; tries++) {
        if (isUdp) {
            if (sendto(fd, out, strlen(out), 0, (struct sockaddr *)&mount, sizeof mount) < 0) return -1;
            n = recvfrom(fd, in, sizeof in - 1, 0, NULL, NULL);
        } else {
            int got = 0;
            if (write(fd, out, strlen(out)) < 0) return -1;
            n = 0;
            while (n < (int)sizeof in - 1 && (got = read(fd, in + n, 1)) == 1) { if (in[n++] == '\r') break; }
        }
        if (n > 0) break;
    }
    if (n <= 0) return -1;
    in[n] = 0;
    snprintf(lastRaw, sizeof lastRaw, "%s", in);
    if (in[n - 1] == '\r') in[--n] = 0;
    if (in[0] == '!') { snprintf(reply, len, "%s", in + 1); return 1; }
    if (in[0] != '=') { snprintf(reply, len, "%s", in); return 1; }
    snprintf(reply, len, "%s", in + 1);
    return 0;
}

/* "563412" -> 0x123456 (low byte first) */
static long hex24(const char *s)
{
    char b[3] = { 0, 0, 0 };
    long v = 0;
    int i, n = (int)strlen(s) / 2;
    for (i = n - 1; i >= 0; i--) { b[0] = s[2 * i]; b[1] = s[2 * i + 1]; v = (v << 8) | strtol(b, NULL, 16); }
    return v;
}

static const char *model_name(int code)
{
    switch (code) {
        case 0x00: return "EQ6";
        case 0x01: return "HEQ5";
        case 0x02: return "EQ5";
        case 0x03: return "EQ3";
        case 0x04: return "EQ8";
        case 0x05: return "AZ-EQ6 (= Orion Atlas Pro AZ/EQ-G)";
        case 0x06: return "AZ-EQ5";
        case 0xA5: return "AZ-GTi";
        default:   return "(not in my list - tell Claude the code)";
    }
}

int main(int argc, char **argv)
{
    const char *target = argc > 1 ? argv[1] : "192.168.4.1";
    char r[64];
    long cpr[3] = { 0, 0, 0 };
    int axis, rc;

    if (target[0] == '/') {
        int baud = argc > 2 ? atoi(argv[2]) : 115200;
        printf("Mount on %s at %d baud\n", target, baud);
        if (open_serial(target, baud) != 0) return 1;
    } else {
        printf("Mount at %s, UDP port 11880 (WiFi)\n", target);
        if (open_udp(target) != 0) return 1;
    }

    rc = ask('e', '1', r, sizeof r);
    if (rc < 0) {
        printf("\nNo answer from the mount.\n");
        printf(" - WiFi: is this computer joined to the mount's WiFi (SynScan_xxxx, password 12345678)?\n");
        printf("         Is the SynScan Pro app closed on every phone/tablet? (only one program can talk to it)\n");
        printf(" - USB : right device (ls /dev/ttyUSB* /dev/ttyACM*)? try 9600 for an EQDIR cable\n");
        return 2;
    }
    if (rc == 0) {
        /* this one answer is written in plain order: "020B05" = firmware 02.0B, mount code 05 */
        long v = strtol(r, NULL, 16);
        int code = (int)(v & 0xFF);
        int major = (int)((v >> 16) & 0xFF), minor = (int)((v >> 8) & 0xFF);
        printf("\nMotor board  : reply '%s'\n", r);
        printf("Mount model  : code 0x%02X = %s\n", code, model_name(code));
        printf("Firmware     : %d.%02d\n", major, minor);
    } else printf("\nMotor board  : error reply '%s'\n", r);
    {   /* exact bytes of the motor board answers, both axes (to identify the mount) */
        int k, ax;
        for (ax = 1; ax <= 2; ax++) {
            ask('e', (char)('0' + ax), r, sizeof r);
            printf("  raw :e%d reply:", ax);
            for (k = 0; lastRaw[k]; k++) printf(" %02X", (unsigned char)lastRaw[k]);
            printf("   \"");
            for (k = 0; lastRaw[k]; k++) putchar(lastRaw[k] == '\r' ? '|' : lastRaw[k]);
            printf("\"\n");
        }
    }

    for (axis = 1; axis <= 2; axis++) {
        char a = (char)('0' + axis);
        const char *nm = axis == 1 ? "RA / azimuth  " : "Dec / altitude";
        long freq = 0, pos = 0;
        printf("\nAxis %d  %s\n", axis, nm);
        if (ask('a', a, r, sizeof r) == 0) { cpr[axis] = hex24(r); printf("  steps per turn : %ld\n", cpr[axis]); }
        else printf("  steps per turn : (no answer '%s')\n", r);
        if (ask('b', a, r, sizeof r) == 0) { freq = hex24(r); printf("  timer frequency: %ld Hz\n", freq); }
        if (ask('j', a, r, sizeof r) == 0) {
            pos = hex24(r) - 0x800000;           /* positions are offset by 0x800000 */
            printf("  position       : %ld steps", pos);
            if (cpr[axis] > 0) printf("  = %.4f deg", pos * 360.0 / cpr[axis]);
            printf("\n");
        }
        if (ask('f', a, r, sizeof r) == 0 && strlen(r) >= 3) {
            int d0 = (int)strtol((char[]){ r[0], 0 }, NULL, 16);
            int d1 = (int)strtol((char[]){ r[1], 0 }, NULL, 16);
            int d2 = (int)strtol((char[]){ r[2], 0 }, NULL, 16);
            printf("  status         : '%s'  %s, %s, %s%s\n", r,
                   (d1 & 1) ? "MOVING" : "stopped",
                   (d0 & 1) ? "tracking/slew mode" : "GoTo mode",
                   (d0 & 2) ? "backwards" : "forwards",
                   (d2 & 1) ? "" : "  (motor not initialised yet)");
        }
    }
    printf("\nRead-only test finished - the mount was not moved.\n");
    close(fd);
    return 0;
}

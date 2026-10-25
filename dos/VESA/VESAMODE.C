/*
 * VESAMODE.C - list every VESA video mode the graphics card offers
 *
 * Builds with Microsoft QuickC 2.5:   QCL /AS VESAMODE.C
 * or Open Watcom (16-bit DOS, small model).
 *
 * Usage:  VESAMODE [/N] [/A] [/F:file]
 *   /N        no "press a key" pauses
 *   /A        also list text modes and modes the card marks unusable
 *   /F:file   report file (default VESAMODE.TXT, /F:- for none)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <dos.h>
#include <conio.h>
#include <io.h>

#ifdef __WATCOMC__
#define FAR __far
#else
#define FAR far
#endif

#define VERSION "1.0"
#define MKFP(s,o)  ((void FAR *)(((unsigned long)(s) << 16) | (unsigned)(o)))
#define PEEKB(s,o) (*(volatile unsigned char FAR *)MKFP(s,o))
#define PEEKW(s,o) (*(volatile unsigned int FAR *)MKFP(s,o))

#define W(b,o)  ((unsigned)((b)[o] | ((b)[(o)+1] << 8)))
#define DW(b,o) ((unsigned long)W(b,o) | ((unsigned long)W(b,(o)+2) << 16))

static FILE *rpt = NULL;
static int paging = 1, lines = 0, showall = 0;

static unsigned char info[512];     /* VbeInfoBlock  */
static unsigned char mi[256];       /* ModeInfoBlock */
static unsigned modes[512];
static char sbuf[128];

static union REGS r;
static struct SREGS sr;

static void out(const char *fmt, ...)
{
    char line[256];
    va_list ap;
    char *p;

    va_start(ap, fmt);
    vsprintf(line, fmt, ap);
    va_end(ap);
    fputs(line, stdout);
    if (rpt) fputs(line, rpt);
    for (p = line; *p; p++) {
        if (*p == '\n' && paging && ++lines >= 23) {
            fputs("-- press a key (Esc = no more pauses) --", stdout);
            if (getch() == 27) paging = 0;
            fputs("\r                                        \r", stdout);
            lines = 0;
        }
    }
}

static char *farstr(unsigned long fp, int max)
{
    unsigned seg = (unsigned)(fp >> 16), off = (unsigned)fp;
    int i;
    unsigned char c;

    if (fp == 0) { strcpy(sbuf, "(none)"); return sbuf; }
    for (i = 0; i < max && i < (int)sizeof(sbuf) - 1; i++) {
        c = PEEKB(seg, off + i);
        if (c == 0) break;
        sbuf[i] = (c >= 32 && c < 127) ? c : '.';
    }
    sbuf[i] = 0;
    while (i > 0 && sbuf[i-1] == ' ') sbuf[--i] = 0;
    return sbuf;
}

static int vbe_info(void)
{
    memset(info, 0, sizeof(info));
    memcpy(info, "VBE2", 4);            /* ask for VBE 2.0 data */
    segread(&sr);
    sr.es = sr.ds;
    r.x.ax = 0x4F00;
    r.x.di = (unsigned)info;
    int86x(0x10, &r, &r, &sr);
    return (r.x.ax == 0x004F && memcmp(info, "VESA", 4) == 0);
}

static int vbe_mode(unsigned mode)
{
    memset(mi, 0, sizeof(mi));
    segread(&sr);
    sr.es = sr.ds;
    r.x.ax = 0x4F01;
    r.x.cx = mode;
    r.x.di = (unsigned)mi;
    int86x(0x10, &r, &r, &sr);
    return (r.x.ax == 0x004F);
}

static const char *model_name(int m)
{
    switch (m) {
        case 0: return "text";
        case 1: return "CGA";
        case 2: return "Herc";
        case 3: return "planar";
        case 4: return "packed";
        case 5: return "unchain";
        case 6: return "direct";
        case 7: return "YUV";
    }
    return "?";
}

int main(int argc, char *argv[])
{
    const char *fname = "VESAMODE.TXT";
    unsigned ver, totmem, nmodes = 0, i, seg, off, m;
    unsigned long caps, p;
    int lfb_count = 0, shown = 0, a;

    for (a = 1; a < argc; a++) {
        if (argv[a][0] == '/' || argv[a][0] == '-') {
            char c = argv[a][1];
            if (c == 'n' || c == 'N') paging = 0;
            else if (c == 'a' || c == 'A') showall = 1;
            else if ((c == 'f' || c == 'F') && argv[a][2] == ':') fname = argv[a] + 3;
            else {
                printf("VESAMODE %s - list VESA video modes\n", VERSION);
                printf("Usage: VESAMODE [/N] [/A] [/F:file]\n");
                printf("  /N       no pauses\n");
                printf("  /A       include text and unusable modes\n");
                printf("  /F:file  report file (default VESAMODE.TXT, /F:- for none)\n");
                return 0;
            }
        }
    }
    if (!isatty(1)) paging = 0;
    if (strcmp(fname, "-") != 0) {
        rpt = fopen(fname, "w");
        if (!rpt) printf("Warning: cannot create %s\n", fname);
    }

    out("VESAMODE %s - VESA video mode report\n", VERSION);
    out("================================================================\n");

    if (!vbe_info()) {
        out("No VESA BIOS extensions found on this video card.\n");
        if (rpt) fclose(rpt);
        return 1;
    }

    ver    = W(info, 4);
    caps   = DW(info, 10);
    totmem = W(info, 18);
    out("VBE version        : %d.%d\n", ver >> 8, ver & 0xFF);
    out("Video memory       : %u KB\n", totmem * 64);
    out("OEM string         : %s\n", farstr(DW(info, 6), 70));
    if (ver >= 0x200) {
        out("Vendor             : %s\n", farstr(DW(info, 22), 70));
        out("Product            : %s\n", farstr(DW(info, 26), 70));
        out("Revision           : %s\n", farstr(DW(info, 30), 70));
        out("OEM software rev   : %d.%d\n", info[21], info[20]);
    }
    out("Capabilities       :%s%s%s\n",
        (caps & 1) ? " DAC-8bit-capable" : " DAC-6bit-only",
        (caps & 2) ? " not-VGA-compatible" : " VGA-compatible",
        (caps & 4) ? " use-blank-bit-for-palette" : "");

    /* protected mode interface (VBE 2.0+) */
    if (ver >= 0x200) {
        segread(&sr);
        r.x.ax = 0x4F0A; r.x.bx = 0;
        int86x(0x10, &r, &r, &sr);
        out("Protected-mode API : %s\n", r.x.ax == 0x004F ? "available (4F0Ah)" : "not available");
    }

    /* copy the mode list first - it may live inside the info block */
    p = DW(info, 14);
    seg = (unsigned)(p >> 16); off = (unsigned)p;
    for (i = 0; i < 511; i++) {
        m = PEEKW(seg, off + i * 2);
        if (m == 0xFFFF) break;
        modes[nmodes++] = m;
    }
    out("Modes in list      : %u\n", nmodes);

    out("\n Mode  Resolution   Bits Model   Colors  Pitch Pages Linear FB  Win KB\n");
    out(" ----  -----------  ---- ------  ------  ----- ----- ---------  ------\n");

    for (i = 0; i < nmodes; i++) {
        unsigned attr, xres, yres, pitch, gran, wsize;
        int bpp, model, pages, usable, graphics, haslfb;
        unsigned long lfb;
        char col[16];

        if (!vbe_mode(modes[i])) {
            if (showall) out(" %04Xh (mode info call failed)\n", modes[i]);
            continue;
        }
        attr     = W(mi, 0);
        usable   = attr & 0x01;
        graphics = (attr & 0x10) ? 1 : 0;
        haslfb   = (attr & 0x80) ? 1 : 0;
        gran     = W(mi, 4);
        wsize    = W(mi, 6);
        pitch    = W(mi, 16);
        xres     = W(mi, 18);
        yres     = W(mi, 20);
        bpp      = mi[25];
        model    = mi[27];
        pages    = mi[29] + 1;
        lfb      = (ver >= 0x200) ? DW(mi, 40) : 0;
        if (!haslfb) lfb = 0;

        if (!showall && (!usable || !graphics)) continue;

        if (model == 6 && mi[31]) {
            /* direct color: show R:G:B bit layout */
            sprintf(col, "%d:%d:%d", mi[31], mi[33], mi[35]);
        } else if (bpp == 4) strcpy(col, "16");
        else if (bpp == 8) strcpy(col, "256");
        else if (bpp == 15) strcpy(col, "32K");
        else if (bpp == 16) strcpy(col, "64K");
        else if (bpp == 24 || bpp == 32) strcpy(col, "16M");
        else strcpy(col, "-");

        if (graphics)
            out(" %04Xh %4u x %-4u  %3d  %-7s %-7s %5u %5d ",
                modes[i], xres, yres, bpp, model_name(model), col, pitch, pages);
        else
            out(" %04Xh %4u x %-4u  text %-7s %-7s %5u %5d ",
                modes[i], xres, yres, model_name(model), "", pitch, pages);
        if (lfb) { out(" %08lXh", lfb); lfb_count++; }
        else     out("     -    ");
        out("  %u/%u", gran, wsize);
        if (!usable) out("  (unusable)");
        out("\n");
        shown++;
    }

    out("\n%d mode(s) shown, %d with a linear framebuffer.\n", shown, lfb_count);
    out("Pages = how many full screens fit in video memory (for page flipping).\n");
    out("Win KB = bank window granularity/size for banked (non-linear) drawing.\n");

    if (rpt) {
        fclose(rpt);
        printf("Report saved to %s\n", fname);
    }
    return 0;
}

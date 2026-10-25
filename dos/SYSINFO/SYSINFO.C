/*
 * SYSINFO.C - DOS system information report
 *
 * Builds with Microsoft QuickC 2.5 + MASM 6.11 (see MAKE.BAT)
 * or Open Watcom C (16-bit DOS, small model).
 *
 * Usage:  SYSINFO [/N] [/NP] [/NK] [/F:file]
 *   /N        no "press a key" pauses on screen
 *   /NP       skip the PnP BIOS device list
 *   /NK       skip the keyboard controller mouse-port test
 *   /F:file   report file name (default SYSINFO.TXT)
 *   /F:-      do not write a report file
 *
 * Probes are read-only except: sound card reset (DSP reset at
 * 2x0h), AdLib timer test (388h), UART FIFO test, mouse reset,
 * BIOS PS/2 mouse reset (INT 15h C2, only if no mouse driver is loaded).
 * 2.0 adds: motherboard (SMBIOS/DMI), PnP BIOS devices, mouse/input
 * diagnosis. SMBIOS tables above 1 MB are read in unreal mode (IO32.OBJ).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <dos.h>
#include <conio.h>
#include <io.h>

#ifdef __WATCOMC__
#define FAR   __far
#define CDECL __cdecl
#else
#define FAR   far
#define CDECL cdecl
#endif

#define VERSION "2.0"

#define MKFP(s,o)  ((void FAR *)(((unsigned long)(s) << 16) | (unsigned)(o)))
#define PEEKB(s,o) (*(volatile unsigned char FAR *)MKFP(s,o))
#define PEEKW(s,o) (*(volatile unsigned int FAR *)MKFP(s,o))

/* ---- assembly helpers (SYSASM.ASM) ---- */
int           CDECL cpu_type(void);
void          CDECL cpuid_get(unsigned long leaf, unsigned long *regs);
void          CDECL read_tsc(unsigned long *lo, unsigned long *hi);
int           CDECL fpu_type(int cpu);
unsigned long CDECL loop_tick(void);
int           CDECL xms_info(unsigned *ver, unsigned long *largest,
                             unsigned long *total, int use32);
int           CDECL pci_bios(unsigned *ver, unsigned *lastbus, int is386);

/* ---- globals ---- */
static FILE *rpt = NULL;
static int   paging = 1;
static int   lines = 0;
static int   g_cpu = 0;            /* cpu_type() result */
static int   g_tsc = 0;            /* TSC available */
static unsigned long g_feat = 0;   /* CPUID(1).EDX */

static union REGS  r;
static struct SREGS sr;
static unsigned char buf[512];

/* ---------------------------------------------------------- */
/* output                                                      */
/* ---------------------------------------------------------- */
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
        if (*p == '\n' && paging) {
            if (++lines >= 23) {
                fputs("-- press a key --", stdout);
                if (getch() == 27) paging = 0;
                fputs("\r                 \r", stdout);
                lines = 0;
            }
        }
    }
}

static void heading(const char *t)
{
    out("\n%s\n", t);
    out("----------------------------------------------------------------\n");
}

/* copy a far string into buf, keep printable chars only */
static char *farstr(unsigned seg, unsigned off, int max)
{
    int i;
    unsigned char c;
    for (i = 0; i < max && i < 255; i++) {
        c = PEEKB(seg, off + i);
        if (c == 0) break;
        buf[i] = (c >= 32 && c < 127) ? c : '.';
    }
    buf[i] = 0;
    /* trim trailing spaces */
    while (i > 0 && buf[i-1] == ' ') buf[--i] = 0;
    return (char *)buf;
}

/* compare bytes at seg:off with a near string */
static int farmatch(unsigned seg, unsigned off, const char *s, int n)
{
    int i;
    for (i = 0; i < n; i++)
        if (PEEKB(seg, off + i) != (unsigned char)s[i]) return 0;
    return 1;
}

static int vector_valid(int intno)
{
    unsigned off = PEEKW(0, intno * 4);
    unsigned seg = PEEKW(0, intno * 4 + 2);
    if (seg == 0 && off == 0) return 0;
    if (PEEKB(seg, off) == 0xCF) return 0;   /* IRET */
    return 1;
}

/* ---------------------------------------------------------- */
/* DOS                                                         */
/* ---------------------------------------------------------- */
static void show_dos(void)
{
    int major, minor, oem;
    char *s;

    heading("OPERATING SYSTEM");

    r.x.ax = 0x3000;
    int86(0x21, &r, &r);
    major = r.h.al; minor = r.h.ah; oem = r.h.bh;
    out("DOS version        : %d.%02d", major, minor);
    if (oem == 0xFF) out("  (Microsoft MS-DOS)\n");
    else if (oem == 0x00) out("  (IBM PC DOS)\n");
    else if (oem == 0xEE) out("  (DR-DOS)\n");
    else if (oem == 0xFD) out("  (FreeDOS)\n");
    else out("  (OEM %02Xh)\n", oem);

    if (major >= 5) {
        r.x.ax = 0x3306;
        int86(0x21, &r, &r);
        out("True DOS version   : %d.%02d", r.h.bl, r.h.bh);
        out("%s\n", (r.h.dh & 0x10) ? "  (DOS loaded HIGH)" : "  (DOS in low memory)");
        r.x.ax = 0x3305;
        int86(0x21, &r, &r);
        out("Boot drive         : %c:\n", 'A' + r.h.dl - 1);
    }

    /* Windows? */
    r.x.ax = 0x1600;
    int86(0x2F, &r, &r);
    if (r.h.al != 0 && r.h.al != 0x80 && r.h.al != 0x01 && r.h.al != 0xFF)
        out("Windows            : Enhanced mode %d.%02d running\n", r.h.al, r.h.ah);
    else {
        r.x.ax = 0x4680;
        int86(0x2F, &r, &r);
        if (r.x.ax == 0)
            out("Windows            : Real/Standard mode running\n");
    }

    s = getenv("COMSPEC");
    out("COMSPEC            : %s\n", s ? s : "(not set)");
    s = getenv("PATH");
    out("PATH               : %s\n", s ? s : "(not set)");
    s = getenv("TEMP");
    if (s) out("TEMP               : %s\n", s);
}

/* ---------------------------------------------------------- */
/* BIOS                                                        */
/* ---------------------------------------------------------- */
static const char *bios_names[] = {
    "Award", "AMI", "American Megatrends", "Phoenix", "Compaq",
    "COMPAQ", "IBM", "Dell", "DELL", "MR BIOS", "Quadtel", "Toshiba",
    "TOSHIBA", "Insyde", "SystemSoft", "Hewlett", "Gateway", "Acer",
    "Zenith", "Tandy", "Olivetti", "AST ", "Chips", NULL
};

static void show_bios(void)
{
    unsigned char model, sub;
    unsigned off;
    int i, n, found = 0;
    unsigned start;
    char *s;

    heading("BIOS / MOTHERBOARD");

    out("BIOS date          : %s\n", farstr(0xF000, 0xFFF5, 8));
    model = PEEKB(0xF000, 0xFFFE);
    out("Model byte         : %02Xh ", model);
    switch (model) {
        case 0xFF: out("(IBM PC)\n"); break;
        case 0xFE: out("(PC/XT)\n"); break;
        case 0xFB: out("(PC/XT)\n"); break;
        case 0xFD: out("(PCjr)\n"); break;
        case 0xFC: out("(AT class)\n"); break;
        case 0xFA: out("(PS/2 Model 30)\n"); break;
        case 0xF8: out("(PS/2 MCA)\n"); break;
        default:   out("\n"); break;
    }

    /* system configuration: INT 15h C0h */
    segread(&sr);
    r.h.ah = 0xC0;
    r.x.cflag = 0;
    int86x(0x15, &r, &r, &sr);
    if (!r.x.cflag && r.h.ah == 0) {
        sub = PEEKB(sr.es, r.x.bx + 3);
        out("Submodel / rev     : %02Xh / %02Xh\n", sub, PEEKB(sr.es, r.x.bx + 4));
    }

    /* scan F000 segment for a vendor string */
    for (off = 0xE000; off < 0xFFF0 && !found; off++) {
        for (i = 0; bios_names[i]; i++) {
            n = strlen(bios_names[i]);
            if (farmatch(0xF000, off, bios_names[i], n)) {
                start = off;
                while (start > 0xE000) {
                    unsigned char c = PEEKB(0xF000, start - 1);
                    if (c < 32 || c > 126) break;
                    start--;
                }
                s = farstr(0xF000, start, 70);
                if (strlen(s) >= 8) {
                    out("BIOS string        : %s\n", s);
                    found = 1;
                }
                break;
            }
        }
    }

    /* keyboard */
    out("Keyboard           : %s\n",
        (PEEKB(0x40, 0x96) & 0x10) ? "Enhanced 101/102-key" : "83/84-key (or not reported)");

    /* APM */
    r.x.ax = 0x5300; r.x.bx = 0; r.x.cflag = 0;
    int86(0x15, &r, &r);
    if (!r.x.cflag && r.x.bx == 0x504D)
        out("APM power mgmt     : version %d.%d\n", r.h.ah, r.h.al);
    else
        out("APM power mgmt     : not present\n");
}


/* ---------------------------------------------------------- */
/* CPU                                                         */
/* ---------------------------------------------------------- */
static const char *cpu_guess(const char *vend, int fam, int mod)
{
    if (strcmp(vend, "GenuineIntel") == 0) {
        if (fam == 4) {
            switch (mod) {
                case 0: case 1: return "Intel 486DX";
                case 2: return "Intel 486SX";
                case 3: return "Intel 486DX2";
                case 4: return "Intel 486SL";
                case 5: return "Intel 486SX2";
                case 7: return "Intel 486DX2 (write-back)";
                case 8: return "Intel 486DX4";
                case 9: return "Intel 486DX4 (write-back)";
            }
            return "Intel 486";
        }
        if (fam == 5) {
            if (mod == 4 || mod == 8) return "Intel Pentium MMX";
            return "Intel Pentium";
        }
        if (fam == 6) {
            switch (mod) {
                case 1: return "Intel Pentium Pro";
                case 3: case 5: return "Intel Pentium II";
                case 6: return "Intel Celeron (Mendocino)";
                case 7: case 8: case 10: case 11: return "Intel Pentium III";
                case 9: case 13: return "Intel Pentium M";
                case 14: return "Intel Core";
                case 15: case 22: case 23: case 29: return "Intel Core 2";
            }
            return "Intel P6 family";
        }
        if (fam == 15) return "Intel Pentium 4 family";
    }
    if (strcmp(vend, "AuthenticAMD") == 0) {
        if (fam == 4) return (mod >= 14) ? "AMD 5x86" : "AMD 486";
        if (fam == 5) {
            if (mod <= 3) return "AMD K5";
            if (mod <= 7) return "AMD K6";
            if (mod == 8) return "AMD K6-2";
            if (mod == 9) return "AMD K6-III";
            return "AMD K6-2+/III+";
        }
        if (fam == 6) return "AMD Athlon / Duron";
        if (fam == 15) return "AMD Athlon 64 family";
    }
    if (strcmp(vend, "CyrixInstead") == 0) {
        if (fam == 4) return "Cyrix 5x86 / MediaGX";
        if (fam == 5) return "Cyrix 6x86";
        if (fam == 6) return "Cyrix 6x86MX / MII";
    }
    if (strcmp(vend, "CentaurHauls") == 0) return "IDT WinChip / VIA";
    if (strcmp(vend, "NexGenDriven") == 0) return "NexGen Nx586";
    if (strcmp(vend, "UMC UMC UMC ") == 0) return "UMC U5";
    return NULL;
}

static void show_cpu(void)
{
    static const char *names[] = {
        "8086/8088", "80186/80188", "80286", "80386", "80486 (no CPUID)", ""
    };
    unsigned long reg[4], maxl, maxe;
    char vend[13], brand[49];
    int fam = 0, mod = 0, step = 0, fpu, i;
    const char *g;
    unsigned long lt;

    heading("PROCESSOR");

    g_cpu = cpu_type();
    if (g_cpu < 5) {
        out("CPU class          : %s\n", names[g_cpu]);
    } else {
        cpuid_get(0L, reg);
        maxl = reg[0];
        memcpy(vend, &reg[1], 4);
        memcpy(vend + 4, &reg[3], 4);
        memcpy(vend + 8, &reg[2], 4);
        vend[12] = 0;
        out("CPU vendor         : %s\n", vend);
        if (maxl >= 1) {
            cpuid_get(1L, reg);
            step = (int)(reg[0] & 0x0F);
            mod  = (int)((reg[0] >> 4) & 0x0F);
            fam  = (int)((reg[0] >> 8) & 0x0F);
            if (fam == 15) fam += (int)((reg[0] >> 20) & 0xFF);
            if (fam == 6 || fam >= 15) mod += (int)((reg[0] >> 12) & 0xF0);
            g_feat = reg[3];
            out("Family/Model/Step  : %d / %d / %d\n", fam, mod, step);
            g = cpu_guess(vend, fam, mod);
            if (g) out("CPU (best guess)   : %s\n", g);
        }
        cpuid_get(0x80000000L, reg);
        maxe = reg[0];
        if (maxe >= 0x80000004L && maxe < 0x8000FFFFL) {
            for (i = 0; i < 3; i++) {
                cpuid_get(0x80000002L + i, reg);
                memcpy(brand + i * 16, reg, 16);
            }
            brand[48] = 0;
            g = brand;
            while (*g == ' ') g++;
            out("CPU brand string   : %s\n", g);
        }
        if (g_feat) {
            out("Features           :");
            if (g_feat & 0x00000001L) out(" FPU");
            if (g_feat & 0x00000010L) out(" TSC");
            if (g_feat & 0x00000020L) out(" MSR");
            if (g_feat & 0x00000100L) out(" CX8");
            if (g_feat & 0x00008000L) out(" CMOV");
            if (g_feat & 0x00800000L) out(" MMX");
            if (g_feat & 0x01000000L) out(" FXSR");
            if (g_feat & 0x02000000L) out(" SSE");
            if (g_feat & 0x04000000L) out(" SSE2");
            if (g_feat & 0x10000000L) out(" HTT");
            out("\n");
            g_tsc = (g_feat & 0x10L) ? 1 : 0;
        }
    }

    /* FPU */
    if (g_cpu == 5 && g_feat) {
        fpu = (g_feat & 1L) ? 4 : 0;
    } else {
        fpu = fpu_type(g_cpu);
    }
    out("Math coprocessor   : ");
    switch (fpu) {
        case 0: out("none\n"); break;
        case 1: out("8087\n"); break;
        case 2: out("80287\n"); break;
        case 3: out(g_cpu >= 4 ? "built-in\n" : "80387\n"); break;
        default: out("built-in\n"); break;
    }

    /* speed */
    if (g_tsc) {
        unsigned long lo1, hi1, lo2, hi2, t;
        unsigned tick;
        double mhz;
        tick = PEEKW(0x40, 0x6C);
        while (PEEKW(0x40, 0x6C) == tick) ;
        read_tsc(&lo1, &hi1);
        tick = PEEKW(0x40, 0x6C);
        while ((unsigned)(PEEKW(0x40, 0x6C) - tick) < 9) ;
        read_tsc(&lo2, &hi2);
        t = lo2 - lo1;
        mhz = (double)t / (9.0 * 54925.4);
        out("Clock speed        : about %.0f MHz (measured with TSC)\n", mhz);
    }
    lt = loop_tick();
    out("Speed index        : %lu loops per timer tick (bigger = faster)\n", lt);
}

/* ---------------------------------------------------------- */
/* Memory                                                      */
/* ---------------------------------------------------------- */
static unsigned char cmos(int reg)
{
    outp(0x70, reg);
    return (unsigned char)inp(0x71);
}

static void show_memory(void)
{
    unsigned conv, xver, mcb, own, largest;
    unsigned long ext = 0, xl, xt;
    unsigned seg;

    heading("MEMORY");

    int86(0x12, &r, &r);
    conv = r.x.ax;
    out("Conventional       : %u KB\n", conv);

    /* largest free block while we run + our own block */
    r.h.ah = 0x48; r.x.bx = 0xFFFF;
    int86(0x21, &r, &r);
    largest = r.x.bx;
    mcb = _psp - 1;
    own = PEEKW(mcb, 3);
    out("Free conventional  : about %lu KB for programs\n",
        ((unsigned long)largest + own) * 16UL / 1024UL);

    /* installed extended memory: E801 first, then CMOS */
    r.x.ax = 0xE801; r.x.cflag = 0;
    r.x.bx = 0; r.x.cx = 0; r.x.dx = 0;
    int86(0x15, &r, &r);
    if (!r.x.cflag && (r.x.ax || r.x.cx)) {
        unsigned lo = r.x.ax ? r.x.ax : r.x.cx;
        unsigned hi = r.x.ax ? r.x.bx : r.x.dx;
        ext = (unsigned long)lo + (unsigned long)hi * 64UL;
    } else if (g_cpu >= 2) {
        ext = (unsigned long)cmos(0x17) | ((unsigned long)cmos(0x18) << 8);
    }
    if (g_cpu >= 2) {
        out("Extended (above 1MB): %lu KB\n", ext);
        out("Total RAM          : about %lu MB\n", (ext + 1024UL) / 1024UL);
    }

    /* XMS */
    if (xms_info(&xver, &xl, &xt, g_cpu >= 3)) {
        out("XMS driver         : version %x.%02x, %lu KB free (largest block %lu KB)\n",
            xver >> 8, xver & 0xFF, xt, xl);
    } else {
        out("XMS driver         : not loaded (no HIMEM.SYS)\n");
    }

    /* EMS */
    seg = PEEKW(0, 0x67 * 4 + 2);
    if (seg && farmatch(seg, 0x0A, "EMMXXXX0", 8)) {
        r.h.ah = 0x46; int86(0x67, &r, &r);
        out("EMS driver         : version %d.%d", r.h.al >> 4, r.h.al & 0x0F);
        r.h.ah = 0x42; int86(0x67, &r, &r);
        if (r.h.ah == 0)
            out(", %u KB free of %u KB", r.x.bx * 16, r.x.dx * 16);
        r.h.ah = 0x41; int86(0x67, &r, &r);
        if (r.h.ah == 0)
            out(", frame %04Xh", r.x.bx);
        out("\n");
    } else {
        out("EMS driver         : not loaded\n");
    }
}


/* ---------------------------------------------------------- */
/* Video                                                       */
/* ---------------------------------------------------------- */
static void show_video(void)
{
    int vga = 0;
    unsigned ver, mem;
    unsigned long p;
    static const char *dcc[] = {
        "none", "MDA", "CGA", "?", "EGA color", "EGA mono", "PGA",
        "VGA mono", "VGA color", "?", "MCGA digital", "MCGA mono", "MCGA color"
    };

    heading("VIDEO");

    r.x.ax = 0x1A00;
    int86(0x10, &r, &r);
    if (r.h.al == 0x1A) {
        vga = (r.h.bl == 7 || r.h.bl == 8);
        out("Display adapter    : %s\n", r.h.bl <= 12 ? dcc[r.h.bl] : "unknown");
    } else {
        r.h.ah = 0x12; r.h.bl = 0x10;
        int86(0x10, &r, &r);
        if (r.h.bl != 0x10)
            out("Display adapter    : EGA, %d KB\n", (r.h.bl + 1) * 64);
        else
            out("Display adapter    : %s\n",
                ((PEEKW(0x40, 0x10) & 0x30) == 0x30) ? "MDA / Hercules" : "CGA");
    }

    r.h.ah = 0x0F;
    int86(0x10, &r, &r);
    out("Current mode       : %02Xh, %d columns\n", r.h.al, r.h.ah);

    if (!vga) return;

    /* VESA BIOS extensions */
    memset(buf, 0, sizeof(buf));
    memcpy(buf, "VBE2", 4);
    segread(&sr);
    sr.es = sr.ds;
    r.x.ax = 0x4F00;
    r.x.di = (unsigned)buf;
    int86x(0x10, &r, &r, &sr);
    if (r.x.ax == 0x004F && memcmp(buf, "VESA", 4) == 0) {
        ver = buf[4] | (buf[5] << 8);
        mem = buf[18] | (buf[19] << 8);
        out("VESA VBE           : version %d.%d, %u KB video memory\n",
            ver >> 8, ver & 0xFF, mem * 64);
        p = *(unsigned long *)(buf + 6);
        {
            unsigned long vp = 0, pp = 0, rp = 0;
            if (ver >= 0x200) {
                vp = *(unsigned long *)(buf + 22);
                pp = *(unsigned long *)(buf + 26);
                rp = *(unsigned long *)(buf + 30);
            }
            out("VESA OEM string    : %s\n",
                farstr((unsigned)(p >> 16), (unsigned)p, 60));
            if (vp) out("Video vendor       : %s\n",
                farstr((unsigned)(vp >> 16), (unsigned)vp, 60));
            if (pp) out("Video product      : %s\n",
                farstr((unsigned)(pp >> 16), (unsigned)pp, 60));
            if (rp) out("Video revision     : %s\n",
                farstr((unsigned)(rp >> 16), (unsigned)rp, 60));
        }
    } else {
        out("VESA VBE           : not supported\n");
    }
}

/* ---------------------------------------------------------- */
/* Disks                                                       */
/* ---------------------------------------------------------- */
static void show_disks(void)
{
    static const char *ftype[] = {
        "none", "360 KB 5.25\"", "1.2 MB 5.25\"", "720 KB 3.5\"",
        "1.44 MB 3.5\"", "2.88 MB 3.5\"", "2.88 MB 3.5\""
    };
    unsigned equip, nfloppy, nhd, d, cyl, heads, secs;
    unsigned long mb;
    int drv, cdcount = 0, cdfirst = 0;
    struct diskfree_t df;

    heading("DISK DRIVES");

    equip = PEEKW(0x40, 0x10);
    nfloppy = (equip & 1) ? ((equip >> 6) & 3) + 1 : 0;
    out("Floppy drives      : %u\n", nfloppy);
    for (d = 0; d < nfloppy && d < 2; d++) {
        segread(&sr);
        r.h.ah = 0x08; r.h.dl = (unsigned char)d; r.x.cflag = 0;
        int86x(0x13, &r, &r, &sr);
        if (!r.x.cflag)
            out("  %c: %s\n", 'A' + d, r.h.bl <= 6 ? ftype[r.h.bl] : "unknown type");
    }

    nhd = PEEKB(0x40, 0x75);
    out("BIOS hard disks    : %u\n", nhd);
    for (d = 0; d < nhd && d < 8; d++) {
        segread(&sr);
        r.h.ah = 0x08; r.h.dl = (unsigned char)(0x80 + d); r.x.cflag = 0;
        int86x(0x13, &r, &r, &sr);
        if (r.x.cflag) {
            out("  Disk %u (%02Xh)     : no geometry reported\n", d, 0x80 + d);
            continue;
        }
        cyl   = ((r.h.cl & 0xC0) << 2) + r.h.ch + 1;
        heads = r.h.dh + 1;
        secs  = r.h.cl & 0x3F;
        mb = (unsigned long)cyl * heads * secs / 2048UL;
        out("  Disk %u (%02Xh)     : C/H/S %u/%u/%u = %lu MB (BIOS geometry)",
            d, 0x80 + d, cyl, heads, secs, mb);

        /* INT 13h extensions */
        r.h.ah = 0x41; r.x.bx = 0x55AA; r.h.dl = (unsigned char)(0x80 + d); r.x.cflag = 0;
        int86(0x13, &r, &r);
        if (!r.x.cflag && r.x.bx == 0xAA55) {
            memset(buf, 0, 30);
            buf[0] = 26;
            segread(&sr);
            r.h.ah = 0x48; r.h.dl = (unsigned char)(0x80 + d);
            r.x.si = (unsigned)buf; r.x.cflag = 0;
            int86x(0x13, &r, &r, &sr);
            if (!r.x.cflag) {
                unsigned long lo = *(unsigned long *)(buf + 16);
                unsigned long hi = *(unsigned long *)(buf + 20);
                if (hi == 0) out("\n                      LBA %lu sectors = %lu MB",
                                 lo, lo / 2048UL);
                else out("\n                      LBA size over 2 TB");
            }
        }
        out("\n");
    }

    /* MSCDEX */
    r.x.ax = 0x1500; r.x.bx = 0;
    int86(0x2F, &r, &r);
    if (r.x.bx) {
        cdcount = r.x.bx; cdfirst = r.x.cx;
        r.x.ax = 0x150C; r.x.bx = 0;
        int86(0x2F, &r, &r);
        out("CD-ROM (MSCDEX)    : %d drive(s), first is %c:, MSCDEX %d.%02d\n",
            cdcount, 'A' + cdfirst, r.h.bh, r.h.bl);
    } else {
        out("CD-ROM (MSCDEX)    : not loaded\n");
    }

    out("\nDOS drives:\n");
    for (drv = 3; drv <= 26; drv++) {
        unsigned attr;
        int removable, remote, subst, cd = 0;
        r.x.ax = 0x4409; r.h.bl = (unsigned char)drv; r.x.cflag = 0;
        int86(0x21, &r, &r);
        if (r.x.cflag) continue;
        attr = r.x.dx;
        remote = (attr & 0x1000) ? 1 : 0;
        subst  = (attr & 0x8000) ? 1 : 0;
        if (cdcount) {
            r.x.ax = 0x150B; r.x.cx = drv - 1;
            int86(0x2F, &r, &r);
            if (r.x.bx == 0xADAD && r.x.ax) cd = 1;
        }
        removable = 0;
        if (!remote && !cd) {
            r.x.ax = 0x4408; r.h.bl = (unsigned char)drv; r.x.cflag = 0;
            int86(0x21, &r, &r);
            if (!r.x.cflag && r.x.ax == 0) removable = 1;
        }
        out("  %c:  ", 'A' + drv - 1);
        if (cd) { out("CD-ROM\n"); continue; }
        if (remote) out("network/redirected ");
        if (subst)  out("SUBST ");
        if (removable) { out("removable\n"); continue; }
        if (_dos_getdiskfree(drv, &df) == 0) {
            unsigned long csize = (unsigned long)df.sectors_per_cluster * df.bytes_per_sector;
            unsigned long totk = (unsigned long)df.total_clusters * (csize / 512UL) / 2UL;
            unsigned long frek = (unsigned long)df.avail_clusters * (csize / 512UL) / 2UL;
            out("fixed  %7lu KB total  %7lu KB free  (%lu byte clusters)\n",
                totk, frek, csize);
        } else {
            out("not ready\n");
        }
    }
}

/* ---------------------------------------------------------- */
/* Ports                                                       */
/* ---------------------------------------------------------- */
static const char *uart_type(unsigned base)
{
    unsigned char iir, s;
    outp(base + 2, 0xC1);           /* enable + clear FIFOs */
    iir = (unsigned char)inp(base + 2);
    outp(base + 2, 0x00);           /* FIFOs off again */
    if ((iir & 0xC0) == 0xC0) return "16550A (FIFO)";
    if ((iir & 0xC0) == 0x80) return "16550 (bad FIFO)";
    s = (unsigned char)inp(base + 7);
    outp(base + 7, 0x5A);
    if (inp(base + 7) != 0x5A) { outp(base + 7, s); return "8250"; }
    outp(base + 7, s);
    return "16450";
}

static void show_ports(void)
{
    int i, n;
    unsigned p, equip;

    heading("PORTS & INPUT");

    n = 0;
    for (i = 0; i < 4; i++) {
        p = PEEKW(0x40, i * 2);
        if (p) {
            out("COM%d               : %03Xh  UART %s\n", i + 1, p, uart_type(p));
            n++;
        }
    }
    if (!n) out("Serial ports       : none\n");

    n = 0;
    for (i = 0; i < 3; i++) {
        p = PEEKW(0x40, 8 + i * 2);
        if (p) { out("LPT%d               : %03Xh\n", i + 1, p); n++; }
    }
    if (!n) out("Parallel ports     : none\n");

    equip = PEEKW(0x40, 0x10);
    out("Game port          : %s\n", (equip & 0x1000) ? "present" : "not reported by BIOS");

    if (vector_valid(0x33)) {
        r.x.ax = 0;
        int86(0x33, &r, &r);
        if (r.x.ax == 0xFFFF) {
            int buttons = r.x.bx == 0xFFFF ? 2 : r.x.bx;
            static const char *mt[] = { "?", "bus", "serial", "InPort", "PS/2", "HP" };
            r.x.ax = 0x24; r.x.bx = 0; r.x.cx = 0;
            int86(0x33, &r, &r);
            out("Mouse driver       : loaded, %d buttons", buttons);
            if (r.x.bx) {
                out(", driver %d.%02x, %s mouse",
                    r.h.bh, r.h.bl, r.h.ch <= 5 ? mt[r.h.ch] : "?");
                if (r.h.ch != 4 && r.h.cl) out(", IRQ %d", r.h.cl);
            }
            out("\n");
        } else {
            out("Mouse driver       : not responding\n");
        }
    } else {
        out("Mouse driver       : not loaded\n");
    }
}

/* ---------------------------------------------------------- */
/* Sound                                                       */
/* ---------------------------------------------------------- */
static void io_delay(unsigned base, int n)
{
    while (n-- > 0) inp(base);
}

static int sb_reset(unsigned base)
{
    long t;
    outp(base + 6, 1);
    io_delay(base + 6, 20);
    outp(base + 6, 0);
    for (t = 0; t < 2000L; t++) {
        if (inp(base + 0x0E) & 0x80) {
            if (inp(base + 0x0A) == 0xAA) return 1;
        }
    }
    return 0;
}

static int sb_write(unsigned base, int v)
{
    long t;
    for (t = 0; t < 20000L; t++)
        if (!(inp(base + 0x0C) & 0x80)) { outp(base + 0x0C, v); return 1; }
    return 0;
}

static int sb_read(unsigned base)
{
    long t;
    for (t = 0; t < 20000L; t++)
        if (inp(base + 0x0E) & 0x80) return inp(base + 0x0A);
    return -1;
}

static void adlib_w(int reg, int val)
{
    outp(0x388, reg); io_delay(0x388, 6);
    outp(0x389, val); io_delay(0x388, 35);
}

static int adlib_detect(void)
{
    int s1, s2, i;
    adlib_w(4, 0x60);
    adlib_w(4, 0x80);
    s1 = inp(0x388);
    adlib_w(2, 0xFF);
    adlib_w(4, 0x21);
    for (i = 0; i < 200; i++) inp(0x388);   /* > 80 us */
    s2 = inp(0x388);
    adlib_w(4, 0x60);
    adlib_w(4, 0x80);
    return ((s1 & 0xE0) == 0x00 && (s2 & 0xE0) == 0xC0);
}

static void show_sound(void)
{
    char *b;
    unsigned base;
    int found = 0, hi, lo;

    heading("SOUND");

    b = getenv("BLASTER");
    out("BLASTER variable   : %s\n", b ? b : "(not set)");

    for (base = 0x220; base <= 0x280; base += 0x20) {
        if (sb_reset(base)) {
            found = 1;
            hi = -1; lo = -1;
            if (sb_write(base, 0xE1)) { hi = sb_read(base); lo = sb_read(base); }
            out("Sound Blaster DSP  : found at %03Xh", base);
            if (hi >= 0) {
                out(", DSP version %d.%02d", hi, lo);
                if (hi == 1) out(" (SB 1.x)");
                else if (hi == 2) out(lo ? " (SB 2.0)" : " (SB 1.5/2.0)");
                else if (hi == 3) out(" (SB Pro)");
                else if (hi == 4) out(" (SB16 / AWE)");
            }
            out("\n");
            break;
        }
    }
    if (!found) out("Sound Blaster DSP  : not found at 220h-280h\n");

    out("AdLib / OPL FM     : %s\n", adlib_detect() ? "present at 388h" : "not detected");
}

/* ---------------------------------------------------------- */
/* PCI                                                         */
/* ---------------------------------------------------------- */
static const char *pci_vendor(unsigned v)
{
    switch (v) {
        case 0x8086: return "Intel";
        case 0x1022: return "AMD";
        case 0x1002: return "ATI";
        case 0x10DE: return "NVIDIA";
        case 0x1106: return "VIA";
        case 0x1039: return "SiS";
        case 0x10B9: return "ALi";
        case 0x5333: return "S3";
        case 0x102B: return "Matrox";
        case 0x121A: return "3dfx";
        case 0x1013: return "Cirrus Logic";
        case 0x1023: return "Trident";
        case 0x10EC: return "Realtek";
        case 0x10B7: return "3Com";
        case 0x1274: return "Ensoniq";
        case 0x1102: return "Creative";
        case 0x125D: return "ESS";
        case 0x1319: return "ForteMedia";
        case 0x13F6: return "C-Media";
        case 0x104C: return "Texas Instruments";
        case 0x1180: return "Ricoh";
        case 0x1217: return "O2 Micro";
        case 0x9004: case 0x9005: return "Adaptec";
        case 0x1000: return "LSI/Symbios";
        case 0x1095: return "CMD/Silicon Image";
        case 0x105A: return "Promise";
        case 0x1078: return "Cyrix";
        case 0x100B: return "National Semi";
        case 0x1060: return "UMC";
        case 0x1045: return "OPTi";
        case 0x1011: return "DEC";
        case 0x1014: return "IBM";
        case 0x0E11: return "Compaq";
        case 0x1028: return "Dell";
        case 0x103C: return "HP";
        case 0x14E4: return "Broadcom";
        case 0x168C: return "Atheros";
        case 0x11C1: return "Lucent/Agere";
        case 0x1186: return "D-Link";
        case 0x10C8: return "NeoMagic";
        case 0x1033: return "NEC";
        case 0x104D: return "Sony";
        case 0x1179: return "Toshiba";
        case 0x15AD: return "VMware";
        case 0x80EE: return "VirtualBox";
    }
    return "";
}

static const char *pci_class(int cls, int sub)
{
    switch (cls) {
        case 0x00: return sub == 1 ? "VGA (old)" : "legacy device";
        case 0x01:
            switch (sub) {
                case 0: return "SCSI controller";
                case 1: return "IDE controller";
                case 2: return "floppy controller";
                case 4: return "RAID controller";
                case 6: return "SATA controller";
            }
            return "storage controller";
        case 0x02: return "network controller";
        case 0x03: return sub == 0 ? "VGA display" : "display controller";
        case 0x04:
            switch (sub) {
                case 0: return "video device";
                case 1: return "audio device";
                case 3: return "HD audio";
            }
            return "multimedia device";
        case 0x05: return "memory controller";
        case 0x06:
            switch (sub) {
                case 0: return "host bridge";
                case 1: return "ISA bridge";
                case 2: return "EISA bridge";
                case 4: return "PCI-PCI bridge";
                case 7: return "CardBus bridge";
            }
            return "bridge";
        case 0x07: return "communication controller";
        case 0x08: return "system peripheral";
        case 0x09: return "input device";
        case 0x0C:
            switch (sub) {
                case 0: return "FireWire controller";
                case 3: return "USB controller";
                case 5: return "SMBus controller";
            }
            return "serial bus controller";
        case 0x0D: return "wireless controller";
    }
    return "other device";
}

static unsigned pci_rw(int bus, int devfn, int reg)
{
    r.x.ax = 0xB109;
    r.h.bh = (unsigned char)bus;
    r.h.bl = (unsigned char)devfn;
    r.x.di = reg;
    r.x.cflag = 0;
    int86(0x1A, &r, &r);
    if (r.x.cflag || r.h.ah) return 0xFFFF;
    return r.x.cx;
}

static void show_pci(void)
{
    unsigned ver, last, ven, dev, cc;
    int bus, slot, fn, maxfn, count = 0;
    unsigned char hdr;

    heading("PCI DEVICES");

    if (!pci_bios(&ver, &last, g_cpu >= 3)) {
        out("PCI BIOS           : not present (ISA/VLB system or pre-386)\n");
        return;
    }
    out("PCI BIOS           : version %x.%02x, last bus %u\n", ver >> 8, ver & 0xFF, last);
    out("  Bus Dev Fn  Vendor:Device  Class\n");
    for (bus = 0; bus <= (int)last; bus++) {
        for (slot = 0; slot < 32; slot++) {
            maxfn = 1;
            for (fn = 0; fn < maxfn; fn++) {
                int devfn = (slot << 3) | fn;
                ven = pci_rw(bus, devfn, 0);
                if (ven == 0xFFFF || ven == 0) continue;
                dev = pci_rw(bus, devfn, 2);
                cc  = pci_rw(bus, devfn, 0x0A);
                if (fn == 0) {
                    hdr = (unsigned char)(pci_rw(bus, devfn, 0x0E) & 0xFF);
                    if (hdr & 0x80) maxfn = 8;
                }
                out("  %3d  %2d  %d   %04X:%04X      %s %s\n",
                    bus, slot, fn, ven, dev, pci_vendor(ven),
                    pci_class(cc >> 8, cc & 0xFF));
                count++;
            }
        }
    }
    out("  %d device(s)\n", count);
}

/* ---------------------------------------------------------- */
/* flat memory (for tables above 1 MB) - IO32.OBJ              */
/* ---------------------------------------------------------- */
int           CDECL unreal_on(void);
unsigned long CDECL mrd32(unsigned long a);

static int flat_ok = -1;

static int a20_on(void)
{
    unsigned char FAR *lo = (unsigned char FAR *)MKFP(0x0000, 0x0500);
    unsigned char FAR *hi = (unsigned char FAR *)MKFP(0xFFFF, 0x0510);
    unsigned char a = *lo, b = *hi;
    int ok;
    *lo = 0x5A; *hi = 0xA5; ok = (*lo == 0x5A); *lo = a; *hi = b;
    if (ok) return 1;
    r.x.ax = 0x2401; int86(0x15, &r, &r);
    a = *lo; b = *hi;
    *lo = 0x5A; *hi = 0xA5; ok = (*lo == 0x5A); *lo = a; *hi = b;
    return ok;
}

/* read 'n' bytes from physical address 'pa' into near buffer */
static int phys_read(unsigned long pa, unsigned char *dst, unsigned n)
{
    unsigned i;
    unsigned long v;
    if (pa + n <= 0x100000UL) {
        for (i = 0; i < n; i++)
            dst[i] = PEEKB((unsigned)((pa + i) >> 4), (unsigned)((pa + i) & 15));
        return 1;
    }
    if (flat_ok < 0) flat_ok = (g_cpu >= 3 && a20_on() && unreal_on() == 0) ? 1 : 0;
    if (!flat_ok) return 0;
    unreal_on();
    for (i = 0; i < n; i += 4) {
        v = mrd32((pa + i) & ~3UL);
        dst[i] = (unsigned char)v;
        if (i + 1 < n) dst[i + 1] = (unsigned char)(v >> 8);
        if (i + 2 < n) dst[i + 2] = (unsigned char)(v >> 16);
        if (i + 3 < n) dst[i + 3] = (unsigned char)(v >> 24);
    }
    return 1;
}

static unsigned rw16(const unsigned char *p) { return p[0] | ((unsigned)p[1] << 8); }
static unsigned long rw32(const unsigned char *p) { return rw16(p) | ((unsigned long)rw16(p + 2) << 16); }

/* ---------------------------------------------------------- */
/* Motherboard: SMBIOS / DMI                                   */
/* ---------------------------------------------------------- */
static unsigned char *smb = NULL;
static unsigned smb_len = 0, smb_count = 0;
static int smb_has_ps2mouse = -1;   /* -1 unknown, 0 no, 1 yes */
static int smb_has_ps2kbd = -1;
static int smb_usb_ports = 0;

/* string number n of the structure at s (formatted length s[1]) */
static const char *smb_str(const unsigned char *s, int n)
{
    static char out_s[72];
    const unsigned char *p = s + s[1];
    int i;
    if (n == 0) return "";
    while (--n > 0) {
        while (*p) p++;
        p++;
        if (*p == 0) return "";
    }
    for (i = 0; i < 70 && p[i]; i++) out_s[i] = (char)((p[i] >= 32 && p[i] < 127) ? p[i] : '.');
    out_s[i] = 0;
    while (i > 0 && out_s[i - 1] == ' ') out_s[--i] = 0;
    return out_s;
}

static const unsigned char *smb_next(const unsigned char *s)
{
    const unsigned char *p = s + s[1];
    while (p[0] || p[1]) p++;
    return p + 2;
}

static const char *port_type_name(int t)
{
    switch (t) {
        case 0x01: return "parallel XT/AT";   case 0x02: return "parallel PS/2";
        case 0x03: return "parallel ECP";     case 0x04: return "parallel EPP";
        case 0x05: return "parallel ECP/EPP"; case 0x08: return "serial 8250";
        case 0x09: return "serial 16450";     case 0x0A: return "serial 16550";
        case 0x0B: return "serial 16550A";    case 0x0D: return "keyboard";
        case 0x0E: return "mouse";            case 0x0F: return "SCSI";
        case 0x10: return "USB";              case 0x11: return "FireWire";
        case 0x1C: return "video";            case 0x1D: return "audio";
        case 0x1E: return "modem";            case 0x1F: return "network";
        case 0xFF: return "other";
    }
    return "";
}

static const char *conn_name(int t)
{
    switch (t) {
        case 0x00: return "";              case 0x05: return "DB-9 male";
        case 0x06: return "DB-15";         case 0x07: return "DB-25 female";
        case 0x08: return "DB-9 male";     case 0x09: return "DB-25 male";
        case 0x0B: return "RJ-45";         case 0x0F: return "PS/2 (mini-DIN)";
        case 0x10: return "infrared";      case 0x12: return "USB";
        case 0x1F: return "mini-jack";     case 0x0D: return "mini-DIN";
        case 0x16: return "on board IDE";  case 0x17: return "on board floppy";
        case 0x18: return "9-pin dual";    case 0x19: return "25-pin dual";
        case 0x1A: return "50-pin dual";   case 0x1B: return "68-pin dual";
        case 0x1C: return "CD-ROM in";     case 0xFF: return "other";
    }
    return "";
}

static void show_board(void)
{
    unsigned seg, off;
    unsigned long taddr = 0;
    int ver_hi = 0, ver_lo = 0, found = 0, i, sum;
    const unsigned char *s, *end;
    unsigned memslots = 0, memused = 0, nports8 = 0;
    unsigned long memtotal = 0;

    heading("MOTHERBOARD (SMBIOS / DMI)");

    for (off = 0; off < 0xFFF0 && !found; off += 16) {
        seg = 0xF000;
        if (farmatch(seg, off, "_SM_", 4)) {
            unsigned elen = PEEKB(seg, off + 5);
            for (sum = 0, i = 0; i < (int)elen; i++) sum += PEEKB(seg, off + i);
            if ((sum & 0xFF) != 0 || elen < 0x1F) continue;
            ver_hi = PEEKB(seg, off + 6); ver_lo = PEEKB(seg, off + 7);
            smb_len = PEEKW(seg, off + 0x16);
            taddr = (unsigned long)PEEKW(seg, off + 0x18) | ((unsigned long)PEEKW(seg, off + 0x1A) << 16);
            smb_count = PEEKW(seg, off + 0x1C);
            found = 1;
        } else if (farmatch(seg, off, "_SM3_", 5)) {          /* SMBIOS 3.x, 64-bit entry */
            ver_hi = PEEKB(seg, off + 7); ver_lo = PEEKB(seg, off + 8);
            smb_len = PEEKW(seg, off + 0x0C);
            taddr = (unsigned long)PEEKW(seg, off + 0x10) | ((unsigned long)PEEKW(seg, off + 0x12) << 16);
            if (PEEKW(seg, off + 0x14) || PEEKW(seg, off + 0x16)) continue;   /* above 4 GB */
            smb_count = 0xFFFF;                                 /* walk until type 127 */
            found = 1;
        } else if (farmatch(seg, off, "_DMI_", 5)) {
            ver_hi = PEEKB(seg, off + 0x0E) >> 4; ver_lo = PEEKB(seg, off + 0x0E) & 15;
            smb_len = PEEKW(seg, off + 6);
            taddr = (unsigned long)PEEKW(seg, off + 8) | ((unsigned long)PEEKW(seg, off + 10) << 16);
            smb_count = PEEKW(seg, off + 12);
            found = 1;
        }
    }
    if (!found) { out("SMBIOS             : not found (BIOS has no DMI tables)\n"); return; }
    out("SMBIOS             : version %d.%d, table at %08lXh\n", ver_hi, ver_lo, taddr);
    if (smb_len == 0 || smb_len > 16000) { out("  (table size %u looks wrong)\n", smb_len); return; }
    smb = (unsigned char *)malloc(smb_len + 4);
    if (!smb) { out("  (not enough memory to read it)\n"); return; }
    if (!phys_read(taddr, smb, smb_len)) {
        out("  (table is above 1 MB and flat memory access failed - EMM386?)\n");
        free(smb); smb = NULL; return;
    }
    smb[smb_len] = smb[smb_len + 1] = smb[smb_len + 2] = smb[smb_len + 3] = 0;

    nports8 = 0;
    end = smb + smb_len;
    /* pass 1: identity */
    for (s = smb, i = 0; s + 4 <= end && (unsigned)i < smb_count && s[1] >= 4 && s[0] != 127; s = smb_next(s), i++) {
        switch (s[0]) {
        case 0:
            out("BIOS vendor        : %s\n", smb_str(s, s[4]));
            out("BIOS version       : %s", smb_str(s, s[5]));
            out("   date %s\n", smb_str(s, s[8]));
            break;
        case 1:
            out("System maker       : %s\n", smb_str(s, s[4]));
            out("System model       : %s", smb_str(s, s[5]));
            if (s[1] > 6 && s[6]) out("  (%s)", smb_str(s, s[6]));
            out("\n");
            break;
        case 2:
            out("Board maker        : %s\n", smb_str(s, s[4]));
            out("Board model        : %s", smb_str(s, s[5]));
            if (s[1] > 6 && s[6]) out("  rev %s", smb_str(s, s[6]));
            out("\n");
            break;
        case 4:
            if (s[1] > 0x17) {
                out("CPU socket         : %s", smb_str(s, s[4]));
                out(", max %u MHz, now %u MHz\n", rw16(s + 0x14), rw16(s + 0x16));
            }
            break;
        case 16:
            if (s[1] >= 0x0F) out("Memory slots       : %u, max %lu MB\n",
                                  rw16(s + 0x0D), rw32(s + 7) / 1024UL);
            break;
        case 17:
            if (s[1] >= 0x15) {
                unsigned sz = rw16(s + 0x0C);
                memslots++;
                if (sz && sz != 0xFFFF) {
                    unsigned long mb = (sz & 0x8000) ? (sz & 0x7FFF) / 1024UL : sz;
                    memused++; memtotal += mb;
                    out("  %-16s : %lu MB", smb_str(s, s[0x10]), mb);
                    if (s[1] > 0x16 && rw16(s + 0x15)) out(" at %u MHz", rw16(s + 0x15));
                    out("\n");
                } else {
                    out("  %-16s : empty\n", smb_str(s, s[0x10]));
                }
            }
            break;
        }
    }
    if (memslots) out("Memory sticks      : %u of %u slots used, %lu MB\n", memused, memslots, memtotal);

    /* pass 2: physical ports and slots */
    out("Ports on the board (as the BIOS lists them):\n");
    for (s = smb, i = 0; s + 4 <= end && (unsigned)i < smb_count && s[1] >= 4 && s[0] != 127; s = smb_next(s), i++) {
        if (s[0] == 8 && s[1] >= 9) {
            const char *pt = port_type_name(s[8]);
            int ext = s[7], in = s[5];
            char nm[40];
            if (nports8++ == 0) { smb_has_ps2mouse = 0; smb_has_ps2kbd = 0; }
            strncpy(nm, smb_str(s, s[6]), 39); nm[39] = 0;
            if (!nm[0]) { strncpy(nm, smb_str(s, s[4]), 39); nm[39] = 0; }
            out("  %-22s %-16s %s\n", nm, pt, conn_name(ext ? ext : in));
            if (s[8] == 0x0E && (ext == 0x0F || in == 0x0F || ext == 0x0D)) smb_has_ps2mouse = 1;
            if (s[8] == 0x0E) smb_has_ps2mouse = 1;
            if (s[8] == 0x0D) smb_has_ps2kbd = 1;
            if (s[8] == 0x10) smb_usb_ports++;
        }
    }
    if (!nports8) out("  (the BIOS doesn't list them)\n");
    out("Expansion slots:\n");
    for (s = smb, i = 0; s + 4 <= end && (unsigned)i < smb_count && s[1] >= 4 && s[0] != 127; s = smb_next(s), i++) {
        if (s[0] == 9 && s[1] >= 0x0C) {
            static const char *use[] = { "?", "other", "unknown", "free", "in use" };
            out("  %-22s %s\n", smb_str(s, s[4]), s[7] <= 4 ? use[s[7]] : "?");
        }
    }
}

/* ---------------------------------------------------------- */
/* PnP BIOS device list                                        */
/* ---------------------------------------------------------- */
typedef int (FAR CDECL *PNPF0)(int, unsigned char FAR *, unsigned FAR *, unsigned);
typedef int (FAR CDECL *PNPF1)(int, unsigned char FAR *, unsigned char FAR *, unsigned, unsigned);

static int pnp_mouse = -1;            /* PNP0F.. node reported */
static int pnp_mouse_irq = -1;

static const char *pnp_name(const char *id)
{
    static const struct { const char *id, *nm; } t[] = {
        {"PNP0000","interrupt controller"}, {"PNP0100","system timer"},
        {"PNP0200","DMA controller"},      {"PNP0303","PS/2 keyboard"},
        {"PNP0301","PS/2 keyboard"},       {"PNP0400","printer port"},
        {"PNP0401","ECP printer port"},    {"PNP0501","serial port 16550"},
        {"PNP0500","serial port"},         {"PNP0700","floppy controller"},
        {"PNP0800","PC speaker"},          {"PNP0B00","real-time clock"},
        {"PNP0C01","system board"},        {"PNP0C02","motherboard resources"},
        {"PNP0C04","math coprocessor"},    {"PNP0A03","PCI bus"},
        {"PNP0A00","ISA bus"},             {"PNP0E03","PCI-ISA bridge"},
        {"PNP0F13","PS/2 mouse"},          {"PNP0F03","PS/2 mouse (MS)"},
        {"PNP0F0E","PS/2 mouse (Logitech)"},{"PNP0F12","PS/2 mouse (Logitech)"},
        {"PNP0F0C","serial mouse"},        {"PNP0F01","serial mouse"},
        {"PNPB02F","game port"},           {"PNP0600","IDE controller"},
        {"PNP0C0C","power button"},        {"PNP0C0F","PCI interrupt link"},
        {"PNP0103","HPET timer"},          {"PNP0C08","ACPI"},
        {NULL,NULL} };
    int i;
    for (i = 0; t[i].id; i++) if (strcmp(t[i].id, id) == 0) return t[i].nm;
    return "";
}

static int opt_nopnp = 0, opt_nokbc = 0;

static void show_pnp(void)
{
    unsigned seg = 0xF000, off, i, sum, nodesize, dataseg;
    unsigned char nnodes, node, FAR *nb;
    unsigned char *nbuf;
    PNPF0 f0; PNPF1 f1;
    int found = 0, count = 0, guard;

    heading("PNP BIOS DEVICES");
    for (off = 0; off < 0xFFF0; off += 16) {
        if (farmatch(seg, off, "$PnP", 4)) {
            unsigned len = PEEKB(seg, off + 5);
            for (sum = 0, i = 0; i < len; i++) sum += PEEKB(seg, off + i);
            if ((sum & 0xFF) == 0 && len >= 0x21) { found = 1; break; }
        }
    }
    if (!found) { out("PnP BIOS           : not found\n"); return; }
    if (opt_nopnp) { out("PnP BIOS           : present (device list skipped, /NP)\n"); return; }
    out("PnP BIOS           : version %d.%d\n", PEEKB(seg, off + 4) >> 4, PEEKB(seg, off + 4) & 15);
    *(unsigned long *)&f0 = ((unsigned long)PEEKW(seg, off + 0x0F) << 16) | PEEKW(seg, off + 0x0D);
    *(unsigned long *)&f1 = *(unsigned long *)&f0;
    dataseg = PEEKW(seg, off + 0x1B);

    if (f0(0, (unsigned char FAR *)&nnodes, (unsigned FAR *)&nodesize, dataseg) != 0 ||
        nodesize == 0 || nodesize > 2048) {
        out("  (BIOS didn't return the device list)\n");
        return;
    }
    nbuf = (unsigned char *)malloc(nodesize + 16);
    if (!nbuf) return;
    nb = (unsigned char FAR *)nbuf;
    out("  %u devices:\n", nnodes);
    node = 0;
    for (guard = 0; node != 0xFF && guard < 64; guard++) {
        unsigned char cur = node;
        unsigned long eid;
        char id[8];
        unsigned p, size;
        char res[64];
        int nres = 0;
        if (f1(1, (unsigned char FAR *)&node, nb, 1, dataseg) != 0) break;
        size = rw16(nbuf);
        eid = ((unsigned long)nbuf[3] << 24) | ((unsigned long)nbuf[4] << 16) |
              ((unsigned)nbuf[5] << 8) | nbuf[6];
        id[0] = (char)('@' + ((eid >> 26) & 31));
        id[1] = (char)('@' + ((eid >> 21) & 31));
        id[2] = (char)('@' + ((eid >> 16) & 31));
        sprintf(id + 3, "%04X", (unsigned)(eid & 0xFFFF));
        res[0] = 0;
        /* walk resource descriptors (allocated resources) after 12-byte header */
        for (p = 12; p < size && p < nodesize && nres < 4; ) {
            unsigned char tag = nbuf[p];
            if (tag & 0x80) { p += 3 + rw16(nbuf + p + 1); continue; }   /* large item */
            if ((tag >> 3) == 0x0F) break;                               /* end tag */
            if ((tag >> 3) == 0x04) {                                    /* IRQ */
                unsigned m = rw16(nbuf + p + 1), b;
                for (b = 0; b < 16; b++) if (m & (1u << b)) {
                    sprintf(res + strlen(res), " IRQ%u", b); nres++;
                    if (id[3] == '0' && id[4] == 'F') pnp_mouse_irq = b;
                }
            } else if ((tag >> 3) == 0x08) {                             /* I/O */
                sprintf(res + strlen(res), " %03Xh", rw16(nbuf + p + 2)); nres++;
            } else if ((tag >> 3) == 0x09) {                             /* fixed I/O */
                sprintf(res + strlen(res), " %03Xh", rw16(nbuf + p + 1) & 0x3FF); nres++;
            }
            p += 1 + (tag & 7);
        }
        out("  %2u  %s  %-22s%s\n", cur, id, pnp_name(id), res);
        if (id[3] == '0' && id[4] == 'F' && id[0] == 'P') pnp_mouse = 1;
        count++;
    }
    if (pnp_mouse < 0) pnp_mouse = 0;
    free(nbuf);
}

/* ---------------------------------------------------------- */
/* Mouse / input diagnosis                                     */
/* ---------------------------------------------------------- */
static int kbc_wait_in(void)          /* wait until controller can take a byte */
{
    unsigned long n;
    for (n = 0; n < 200000UL; n++) if (!(inp(0x64) & 2)) return 1;
    return 0;
}

static int kbc_read(void)             /* wait for a byte, -1 on timeout */
{
    unsigned long n;
    for (n = 0; n < 400000UL; n++) if (inp(0x64) & 1) return inp(0x60);
    return -1;
}

static void show_input(void)
{
    unsigned equip = PEEKW(0x40, 0x10);
    int c2 = -1, c2init = -1, c2id = -1, aux = -1, cmdb = -1;
    int mask12, i;
    unsigned v74s, v74o;

    heading("MOUSE / INPUT");

    out("BIOS equipment     : pointing device %s\n", (equip & 4) ? "REPORTED" : "not reported");

    i = 0;
    if (vector_valid(0x33)) { r.x.ax = 0; int86(0x33, &r, &r); i = (r.x.ax == 0xFFFF); }
    if (i) {
        out("BIOS mouse service : (not probed - a mouse driver is loaded and working)\n");
        c2 = 0; c2id = -1;
        goto after_c2;
    }
    /* INT 15h C2xx: BIOS PS/2 pointing device services */
    r.x.ax = 0xC201; r.x.cflag = 0;                  /* reset */
    int86(0x15, &r, &r);
    c2 = r.x.cflag ? r.h.ah : 0;
    if (!r.x.cflag) c2id = r.h.bh;
    r.x.ax = 0xC205; r.h.bh = 3; r.x.cflag = 0;       /* initialise, 3-byte packets */
    int86(0x15, &r, &r);
    c2init = r.x.cflag ? r.h.ah : 0;
    r.x.ax = 0xC200; r.h.bh = 0; int86(0x15, &r, &r); /* leave it disabled */
    out("BIOS mouse service : INT 15h C2xx ");
    if (c2 == 0) out("works, device ID %d%s\n", c2id, c2id == 0 ? " (standard PS/2 mouse)" :
                     c2id == 3 ? " (wheel mouse)" : "");
    else out("FAILED (code %02Xh: %s)\n", c2,
             c2 == 1 ? "not supported" : c2 == 3 ? "interface error" :
             c2 == 4 ? "resend" : c2 == 5 ? "no device" : c2 == 0x86 ? "not supported" : "?");
    if (c2 == 0) out("                     initialise: %s\n", c2init == 0 ? "OK" : "failed");
after_c2:

    /* keyboard controller (8042, real or emulated by the BIOS) */
    if (!opt_nokbc) {
        _disable();
        if (kbc_wait_in()) { outp(0x64, 0x20); cmdb = kbc_read(); }
        if (kbc_wait_in()) { outp(0x64, 0xA9); aux = kbc_read(); }
        _enable();
    } else aux = -2;
    out("Keyboard ctrl 8042 : command byte %s",
        cmdb < 0 ? "no answer" : "");
    if (cmdb >= 0) out("%02Xh (mouse IRQ %s, mouse clock %s)", cmdb,
                       (cmdb & 2) ? "on" : "off", (cmdb & 0x20) ? "OFF" : "on");
    out("\n");
    out("Mouse port test    : %s\n", aux == -2 ? "skipped (/NK)" : aux < 0 ? "no answer" :
        aux == 0 ? "OK - the controller has a mouse (aux) port" :
        "FAILED - no mouse port behind the controller");

    mask12 = (inp(0xA1) >> 4) & 1;
    v74o = PEEKW(0, 0x74 * 4); v74s = PEEKW(0, 0x74 * 4 + 2);
    out("IRQ 12 (mouse)     : %s, handler at %04X:%04X\n",
        mask12 ? "masked (off)" : "enabled", v74s, v74o);

    /* USB legacy (BIOS emulation) per USB 1.1 controller */
    {
        unsigned ver, last, ven, cc, leg, io, ps;
        int bus, slot, fn, k = 0, p;
        if (pci_bios(&ver, &last, g_cpu >= 3)) {
            out("USB legacy (BIOS emulation) per USB 1.1 controller:\n");
            for (bus = 0; bus <= (int)last; bus++)
            for (slot = 0; slot < 32; slot++)
            for (fn = 0; fn < 8; fn++) {
                int devfn = (slot << 3) | fn;
                ven = pci_rw(bus, devfn, 0);
                if (ven == 0xFFFF || ven == 0) { if (fn == 0) break; continue; }
                cc = pci_rw(bus, devfn, 0x0A);
                if (cc != 0x0C03 || (pci_rw(bus, devfn, 0x08) >> 8) != 0) continue;
                k++;
                leg = pci_rw(bus, devfn, 0xC0);
                io = pci_rw(bus, devfn, 0x20) & 0xFFE0;
                out("  #%d %02X:%02X.%X  LEGSUP %04X:", k, bus, slot, fn, leg);
                if (leg & 0x0010) out(" BIOS-handles-USB");
                if (leg & 0x000F) out(" traps-60h/64h");
                if (leg & 0x0020) out(" A20-passthru");
                if (!(leg & 0x003F)) out(" (BIOS not using it)");
                out("\n     ports:");
                for (p = 0; p < 2; p++) {
                    ps = io ? inpw(io + 0x10 + p * 2) : 0;
                    out("  %d=%s", p + 1, !(ps & 1) ? "empty" : (ps & 0x100) ? "low-speed (kbd/mouse)" : "full-speed device");
                }
                out("\n");
            }
        }
    }

    /* INT 33h driver */
    i = 0;
    if (vector_valid(0x33)) { r.x.ax = 0; int86(0x33, &r, &r); i = (r.x.ax == 0xFFFF); }
    out("Mouse driver INT33 : %s\n", i ? "loaded and answering" : "none answering");

    /* verdict */
    out("\nWhat this means:\n");
    if (smb_has_ps2mouse == 1) out("  * The board HAS a PS/2 mouse port - a PS/2 mouse should just work.\n");
    else if (smb_has_ps2mouse == 0) out("  * The board's port list shows no PS/2 mouse port.\n");
    if (c2id == -1 && c2 == 0) out("  * A mouse driver is loaded and working.\n");
    else if (c2 == 0) out("  * The BIOS offers a PS/2 mouse - CTMOUSE /P should find it.\n");
    else out("  * The BIOS is NOT presenting any PS/2 mouse (real or emulated USB).\n");
    if (aux >= 0 && aux != 0) out("  * The keyboard controller has no working mouse port right now.\n");
    if (pnp_mouse == 1) out("  * The BIOS lists a PS/2 mouse device%s.\n", pnp_mouse_irq >= 0 ? " with its IRQ" : "");
    else if (pnp_mouse == 0) out("  * The BIOS device list has no mouse in it (IRQ 12 not reserved).\n");
    if (c2 != 0)
        out("  -> Options: enable USB mouse/PS-2 mouse in BIOS setup, plug in a\n"
            "     PS/2 or serial mouse, or use a USB mouse driver that talks to\n"
            "     the USB controller directly (like USBXFER does for the stick).\n");
}

/* ---------------------------------------------------------- */
/* main                                                        */
/* ---------------------------------------------------------- */
int main(int argc, char *argv[])
{
    const char *fname = "SYSINFO.TXT";
    int i;
    struct dosdate_t dd;
    struct dostime_t dt;

    for (i = 1; i < argc; i++) {
        if ((argv[i][0] == '/' || argv[i][0] == '-')) {
            char c = argv[i][1];
            char c2 = argv[i][2];
            if ((c == 'n' || c == 'N') && (c2 == 'p' || c2 == 'P')) opt_nopnp = 1;
            else if ((c == 'n' || c == 'N') && (c2 == 'k' || c2 == 'K')) opt_nokbc = 1;
            else if (c == 'n' || c == 'N') paging = 0;
            else if ((c == 'f' || c == 'F') && argv[i][2] == ':') fname = argv[i] + 3;
            else if (c == '?' || c == 'h' || c == 'H') {
                printf("SYSINFO %s - DOS system information\n", VERSION);
                printf("Usage: SYSINFO [/N] [/NP] [/NK] [/F:file]\n");
                printf("  /N       no pauses\n");
                printf("  /NP      skip the PnP BIOS device list\n");
                printf("  /NK      skip the keyboard controller mouse-port test\n");
                printf("  /F:file  report file (default SYSINFO.TXT, /F:- for none)\n");
                return 0;
            }
        }
    }
    if (!isatty(1)) paging = 0;

    if (strcmp(fname, "-") != 0) {
        rpt = fopen(fname, "w");
        if (!rpt) printf("Warning: cannot create %s\n", fname);
    }

    _dos_getdate(&dd);
    _dos_gettime(&dt);
    out("SYSINFO %s - system report  %04d-%02d-%02d %02d:%02d\n",
        VERSION, dd.year, dd.month, dd.day, dt.hour, dt.minute);
    out("================================================================\n");

    show_dos();
    show_bios();
    show_cpu();
    show_memory();
    show_video();
    show_disks();
    show_ports();
    show_sound();
    show_pci();
    show_board();
    show_pnp();
    show_input();

    out("\nEnd of report.\n");
    if (rpt) {
        fclose(rpt);
        printf("Report saved to %s\n", fname);
    }
    return 0;
}

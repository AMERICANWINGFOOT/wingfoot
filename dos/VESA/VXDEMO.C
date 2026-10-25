/*
 * VXDEMO.C - VESA 2.0 high-color demo using unreal mode
 *
 * Draws straight into the linear framebuffer in 65,536-color modes,
 * on a hidden page, then flips pages with VBE function 4F07h.
 *
 * Build with QuickC 2.5 + MASM 6.11 (see MAKE.BAT), or Open Watcom.
 *
 * Usage:  VXDEMO [/R:640|800|1024|1280] [/E:1|2] [/T:frames]
 *   /R  screen width (default 800)    /E  starting effect
 *   /T  run that many frames then quit (benchmark)
 * Keys:   1 = plasma   2 = starfield   SPACE = new colors
 *         S = save screenshot (VXSHOTnn.BMP)   ESC = quit
 *
 * Needs a 386+, a VESA 2.0 card with a 16-bit linear-framebuffer
 * mode, and no EMM386/QEMM loaded (unreal mode needs real mode).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <dos.h>
#include <conio.h>

#ifdef __WATCOMC__
#define FAR   __far
#define CDECL __cdecl
#else
#define FAR   far
#define CDECL cdecl
#endif

#define MKFP(s,o)  ((void FAR *)(((unsigned long)(s) << 16) | (unsigned)(o)))
#define PEEKW(s,o) (*(volatile unsigned int FAR *)MKFP(s,o))
#define W(b,o)  ((unsigned)((b)[o] | ((b)[(o)+1] << 8)))
#define DW(b,o) ((unsigned long)W(b,o) | ((unsigned long)W(b,(o)+2) << 16))

/* ---- VXASM.ASM ---- */
int  CDECL vx_unreal(void);
int  CDECL vx_a20(void);
void CDECL vx_fill32(unsigned long addr, unsigned long count, unsigned long value);
void CDECL vx_copy(unsigned long dst, void *src, unsigned bytes);
void CDECL vx_copyin(void *dst, unsigned long src, unsigned bytes);
void CDECL vx_put16(unsigned long addr, unsigned color);
unsigned char FAR * CDECL vx_font8(void);

#define MAXW 1280
#define NSTARS 1200

static union REGS r;
static struct SREGS sr;
static unsigned char info[512], mi[256];

static unsigned scrw, scrh, pitch, vmode;
static unsigned long lfb, pagebytes;
static int drawpage = 1, flipwait = 1;
static unsigned char FAR *font;

static unsigned rowbuf[MAXW];
static int xa[MAXW];
static unsigned char sn[256];
static unsigned pal[256];

static int sx[NSTARS], sy[NSTARS], sz[NSTARS];

/* ---------------------------------------------------------- */
static unsigned rgb(int rr, int gg, int bb)
{
    return (unsigned)(((rr >> 3) << 11) | ((gg >> 2) << 5) | (bb >> 3));
}

static unsigned ticks(void)
{
    return PEEKW(0x40, 0x6C);
}

/* find a 16-bit 5:6:5 linear-framebuffer mode with width w */
static int find_mode(unsigned w)
{
    unsigned long p;
    unsigned seg, off, m, i;

    memset(info, 0, sizeof(info));
    memcpy(info, "VBE2", 4);
    segread(&sr); sr.es = sr.ds;
    r.x.ax = 0x4F00; r.x.di = (unsigned)info;
    int86x(0x10, &r, &r, &sr);
    if (r.x.ax != 0x004F || memcmp(info, "VESA", 4) != 0) return -1;
    if (W(info, 4) < 0x200) return -2;

    p = DW(info, 14);
    seg = (unsigned)(p >> 16); off = (unsigned)p;
    for (i = 0; i < 512; i++) {
        m = PEEKW(seg, off + i * 2);
        if (m == 0xFFFF) break;
        memset(mi, 0, sizeof(mi));
        segread(&sr); sr.es = sr.ds;
        r.x.ax = 0x4F01; r.x.cx = m; r.x.di = (unsigned)mi;
        int86x(0x10, &r, &r, &sr);
        if (r.x.ax != 0x004F) continue;
        if ((W(mi, 0) & 0x99) != 0x99) continue;   /* usable, color, graphics, LFB */
        if (mi[25] != 16 || mi[27] != 6) continue;   /* 16 bpp direct color */
        if (W(mi, 18) != w) continue;
        if (mi[29] < 1) continue;                    /* need 2+ pages */
        vmode = m;
        scrw  = W(mi, 18);
        scrh  = W(mi, 20);
        pitch = W(mi, 16);
        lfb   = DW(mi, 40);
        pagebytes = (unsigned long)pitch * scrh;
        return 0;
    }
    return -3;
}

static int set_mode(void)
{
    r.x.ax = 0x4F02;
    r.x.bx = vmode | 0x4000;        /* bit 14 = linear framebuffer */
    int86(0x10, &r, &r);
    return r.x.ax == 0x004F;
}

static void text_mode(void)
{
    r.x.ax = 0x0003;
    int86(0x10, &r, &r);
}

static void wait_retrace(void)
{
    while (inp(0x3DA) & 8) ;
    while (!(inp(0x3DA) & 8)) ;
}

/* show the page we just drew, start drawing on the other one */
static void flip(void)
{
    r.x.ax = 0x4F07;
    r.x.bx = flipwait ? 0x0080 : 0x0000;    /* 80h = during retrace */
    r.x.cx = 0;
    r.x.dx = drawpage * scrh;
    int86(0x10, &r, &r);
    if (r.x.ax != 0x004F && flipwait) {
        flipwait = 0;                        /* card lacks 80h: do it by hand */
        wait_retrace();
        r.x.ax = 0x4F07; r.x.bx = 0; r.x.cx = 0; r.x.dx = drawpage * scrh;
        int86(0x10, &r, &r);
    } else if (!flipwait) {
        wait_retrace();
    }
    drawpage ^= 1;
    vx_unreal();     /* BIOS calls may reset segment limits */
}

static unsigned long page_addr(void)
{
    return lfb + (unsigned long)drawpage * pagebytes;
}

/* ---------------------------------------------------------- */
/* text overlay using the BIOS 8x8 font, drawn 2x size         */
/* ---------------------------------------------------------- */
static void draw_text(int x, int y, const char *s, unsigned color)
{
    unsigned long base = page_addr();
    int len = strlen(s), row, col, i;
    unsigned char bits;
    unsigned long a;
    int boxw;

    /* clip to the screen width */
    if (x + len * 16 + 4 > (int)scrw) len = ((int)scrw - x - 4) / 16;
    if (len <= 0) return;
    boxw = (len * 16 + 8 + 1) & ~1;

    /* dark box behind the text */
    for (row = -4; row < 20; row++) {
        a = base + (unsigned long)(y + row) * pitch + (unsigned long)(x - 4) * 2;
        vx_fill32(a, (unsigned long)boxw / 2, 0UL);
    }
    for (i = 0; i < len; i++) {
        unsigned char ch = (unsigned char)s[i];
        if (ch > 127) ch = '?';
        for (row = 0; row < 8; row++) {
            bits = font[ch * 8 + row];
            for (col = 0; col < 8; col++) {
                if (bits & (0x80 >> col)) {
                    a = base + (unsigned long)(y + row * 2) * pitch
                             + (unsigned long)(x + i * 16 + col * 2) * 2;
                    vx_put16(a, color);
                    vx_put16(a + 2, color);
                    vx_put16(a + pitch, color);
                    vx_put16(a + pitch + 2, color);
                }
            }
        }
    }
}

/* ---------------------------------------------------------- */
/* plasma                                                      */
/* ---------------------------------------------------------- */
static void make_palette(int seed)
{
    int i;
    double a = seed * 0.9, b = seed * 1.7 + 2.0, c = seed * 2.3 + 4.0;
    for (i = 0; i < 256; i++) {
        double t = i * 6.2831853 / 256.0;
        int rr = (int)(128 + 127 * sin(t + a));
        int gg = (int)(128 + 127 * sin(t * 2 + b));
        int bb = (int)(128 + 127 * sin(t * 3 + c));
        pal[i] = rgb(rr, gg, bb);
    }
}

static void plasma_frame(unsigned t)
{
    unsigned x, y, yv, k;
    unsigned long a = page_addr();
    unsigned char t1 = (unsigned char)(t * 2), t2 = (unsigned char)(t * 3);
    unsigned char t3 = (unsigned char)(t * 5), t4 = (unsigned char)(t * 1);
    unsigned shift = (unsigned char)t;

    for (x = 0; x < scrw; x++)
        xa[x] = sn[(unsigned char)((x >> 1) + t1)] + sn[(unsigned char)((x / 3) - t2)];

    for (y = 0; y < scrh; y++) {
        yv = sn[(unsigned char)((y >> 1) + t3)] + sn[(unsigned char)((y / 3) - t4)];
        k = y + t;
        for (x = 0; x < scrw; x++) {
            unsigned v = xa[x] + yv + sn[(unsigned char)((x + k) >> 2)];
            rowbuf[x] = pal[(unsigned char)((v >> 1) + shift)];
        }
        vx_copy(a, rowbuf, scrw * 2);
        a += pitch;
    }
}

/* ---------------------------------------------------------- */
/* starfield                                                   */
/* ---------------------------------------------------------- */
static void new_star(int i, int farz)
{
    sx[i] = (rand() % 2001) - 1000;
    sy[i] = (rand() % 2001) - 1000;
    sz[i] = farz ? 1000 : (rand() % 999) + 1;
}

static void stars_frame(int hue)
{
    unsigned long base = page_addr(), a;
    int i, cx = scrw / 2, cy = scrh / 2, px, py, br;
    long scale = (long)scrw / 2;

    vx_fill32(base, pagebytes / 4, 0UL);
    for (i = 0; i < NSTARS; i++) {
        sz[i] -= 6;
        if (sz[i] < 2) { new_star(i, 1); continue; }
        px = cx + (int)((long)sx[i] * scale / sz[i]);
        py = cy + (int)((long)sy[i] * scale / sz[i]);
        if (px < 0 || py < 0 || px >= (int)scrw - 1 || py >= (int)scrh - 1) {
            new_star(i, 1);
            continue;
        }
        br = 255 - sz[i] / 4;
        if (br < 0) br = 0;
        a = base + (unsigned long)py * pitch + (unsigned long)px * 2;
        {
            unsigned c;
            if (hue == 0) c = rgb(br, br, br);
            else if (hue == 1) c = rgb(br / 2, br, br);
            else c = rgb(br, br * 3 / 4, br / 3);
            vx_put16(a, c);
            if (sz[i] < 400) {              /* near stars are bigger */
                vx_put16(a + 2, c);
                vx_put16(a + pitch, c);
                vx_put16(a + pitch + 2, c);
            }
        }
    }
}

/* ---------------------------------------------------------- */
/* screenshot of the page on screen -> 24-bit BMP              */
/* ---------------------------------------------------------- */
static void put32(FILE *f, unsigned long v)
{
    fputc((int)(v & 255), f); fputc((int)((v >> 8) & 255), f);
    fputc((int)((v >> 16) & 255), f); fputc((int)((v >> 24) & 255), f);
}

static int shotno = 0;

static void screenshot(void)
{
    static unsigned char line[MAXW * 3];
    char name[16];
    FILE *f;
    unsigned long src, rowbytes, imgsize;
    unsigned x, c;
    int y;

    /* next unused name VXSHOT00.BMP .. VXSHOT99.BMP */
    for (; shotno < 100; shotno++) {
        sprintf(name, "VXSHOT%02d.BMP", shotno);
        f = fopen(name, "rb");
        if (!f) break;
        fclose(f);
    }
    if (shotno >= 100) return;
    shotno++;
    f = fopen(name, "wb");
    if (!f) return;
    rowbytes = ((unsigned long)scrw * 3 + 3) & ~3UL;
    imgsize = rowbytes * scrh;
    fputc('B', f); fputc('M', f);
    put32(f, 54UL + imgsize); put32(f, 0UL); put32(f, 54UL);
    put32(f, 40UL); put32(f, (unsigned long)scrw); put32(f, (unsigned long)scrh);
    put32(f, 1UL | (24UL << 16)); put32(f, 0UL); put32(f, imgsize);
    put32(f, 2835UL); put32(f, 2835UL); put32(f, 0UL); put32(f, 0UL);
    /* the page on screen is the one we are NOT drawing on */
    for (y = (int)scrh - 1; y >= 0; y--) {
        src = lfb + (unsigned long)(drawpage ^ 1) * pagebytes + (unsigned long)y * pitch;
        vx_copyin(rowbuf, src, scrw * 2);
        for (x = 0; x < scrw; x++) {
            c = rowbuf[x];
            line[x * 3 + 0] = (unsigned char)((c & 0x1F) << 3);
            line[x * 3 + 1] = (unsigned char)(((c >> 5) & 0x3F) << 2);
            line[x * 3 + 2] = (unsigned char)(((c >> 11) & 0x1F) << 3);
        }
        fwrite(line, 1, (unsigned)rowbytes, f);
    }
    fclose(f);
    vx_unreal();
}

/* ---------------------------------------------------------- */
int main(int argc, char *argv[])
{
    unsigned want = 800, t = 0, frames = 0, t0, fps = 0;
    int i, effect = 1, seed = 0, rc, hue = 0;
    char msg[80];
    long total_frames = 0;
    unsigned start_tick;
    long maxframes = 0;

    for (i = 1; i < argc; i++) {
        if ((argv[i][0] == '/' || argv[i][0] == '-') &&
            (argv[i][1] == 'r' || argv[i][1] == 'R') && argv[i][2] == ':')
            want = (unsigned)atoi(argv[i] + 3);
        else if ((argv[i][0] == '/' || argv[i][0] == '-') &&
                 (argv[i][1] == 't' || argv[i][1] == 'T') && argv[i][2] == ':')
            maxframes = atol(argv[i] + 3);
        else if ((argv[i][0] == '/' || argv[i][0] == '-') &&
                 (argv[i][1] == 'e' || argv[i][1] == 'E') && argv[i][2] == ':')
            effect = atoi(argv[i] + 3) == 2 ? 2 : 1;
        else {
            printf("VXDEMO - VESA 2.0 high-color demo (unreal mode)\n");
            printf("Usage: VXDEMO [/R:640|800|1024|1280] [/E:1|2] [/T:frames]\n");
            printf("  /R  screen width   /E  starting effect   /T  frames then quit\n");
            printf("Keys:  1 plasma, 2 starfield, SPACE new colors, S screenshot, ESC quit\n");
            return 0;
        }
    }

    rc = find_mode(want);
    if (rc == -1) { printf("No VESA BIOS found.\n"); return 1; }
    if (rc == -2) { printf("VESA 2.0 or later is needed for a linear framebuffer.\n"); return 1; }
    if (rc == -3) {
        printf("No %u-wide 65,536-color mode with a linear framebuffer and 2 pages.\n", want);
        printf("Try VXDEMO /R:640 or /R:800, or run VESAMODE to see what the card offers.\n");
        return 1;
    }
    if (!vx_unreal()) {
        printf("Cannot enter unreal mode: the CPU is in V86 mode.\n");
        printf("Boot without EMM386/QEMM (or exit Windows) and try again.\n");
        return 1;
    }
    if (!vx_a20()) {
        printf("Cannot enable the A20 line.\n");
        return 1;
    }

    for (i = 0; i < 256; i++)
        sn[i] = (unsigned char)(127.5 + 127.5 * sin(i * 6.2831853 / 256.0));
    make_palette(seed);
    for (i = 0; i < NSTARS; i++) new_star(i, 0);
    font = vx_font8();

    if (!set_mode()) { printf("Mode %04Xh could not be set.\n", vmode); return 1; }
    vx_unreal();

    /* clear both pages */
    vx_fill32(lfb, pagebytes / 2, 0UL);

    t0 = ticks();
    start_tick = t0;
    for (;;) {
        if (kbhit()) {
            int k = getch();
            if (k == 0) { getch(); k = 0; }
            if (k == 27) break;
            if (k == '1') effect = 1;
            if (k == '2') effect = 2;
            if (k == ' ') { seed++; make_palette(seed); hue = (hue + 1) % 3; }
            if (k == 's' || k == 'S') screenshot();
        }

        if (effect == 1) plasma_frame(t);
        else stars_frame(hue);

        sprintf(msg, "%ux%u 64K colors %u FPS", scrw, scrh, fps);
        draw_text(12, 12, msg, rgb(255, 255, 255));
        draw_text(12, 36, "1 plasma 2 stars SPC color S shot", rgb(255, 255, 160));

        flip();
        t++;
        frames++;
        total_frames++;
        if (maxframes && total_frames >= maxframes) {
            screenshot();
            break;
        }
        if ((unsigned)(ticks() - t0) >= 18) {
            unsigned dt = ticks() - t0;
            fps = (unsigned)((frames * 182UL) / (dt * 10UL));
            frames = 0;
            t0 = ticks();
        }
    }

    text_mode();
    {
        unsigned dt = ticks() - start_tick;
        printf("VXDEMO: mode %04Xh %ux%u, pitch %u, LFB at %08lXh\n",
               vmode, scrw, scrh, pitch, lfb);
        if (dt)
            printf("%ld frames in %.1f seconds = %.1f FPS average\n",
                   total_frames, dt / 18.2, total_frames * 18.2 / dt);
    }
    return 0;
}

/*
 *  USBMOUSE.C - USB mouse driver for DOS (INT 33h), no BIOS help needed
 *
 *  For PCs whose BIOS emulates only a USB keyboard. USBMOUSE:
 *    - finds a USB 1.1 (UHCI) controller that has the mouse on it and
 *      NOT the keyboard (it peeks at the BIOS's own USB schedule),
 *    - takes that controller over, sets the mouse up in "boot protocol"
 *      (the simple 3/4-byte report every USB mouse supports),
 *    - lets the controller poll the mouse in the background (ping-pong
 *      chains of transfer descriptors), and collects the reports on every
 *      timer tick and every INT 33h call,
 *    - provides the Microsoft mouse API on INT 33h and draws the cursor
 *      in text modes and in VGA mode 13h.
 *  It stays resident (TSR). USBMOUSE /U unloads it.
 *
 *  Build (QuickC 2.5):
 *    qcl /c /AS /Ox /Gs /W3 USBMOUSE.C
 *    qcl /AS USBMOUSE.OBJ MOUSEASM.OBJ IO32.OBJ /link /ST:2048
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dos.h>
#include <conio.h>

typedef unsigned char  u8;
typedef unsigned int   u16;
typedef unsigned long  u32;
typedef volatile unsigned long vu32;

#define VERSION "1.0"

/* IO32.OBJ */
extern void outpd32(unsigned port, unsigned lo, unsigned hi);
extern unsigned long inpd32(unsigned port);
extern int  unreal_on(void);
extern unsigned long mrd32(unsigned long a);
/* MOUSEASM.OBJ */
extern void install_hooks(void);
extern int  remove_hooks(void);
extern void call_handler(u16 ax, u16 bx, u16 cx, u16 dx, u16 si, u16 di);

/* shared with MOUSEASM */
u16  regs33[9];                 /* ax bx cx dx si di bp es ds */
u8   in33 = 0, busy08 = 0;
u8   stk33[1024];
u8   stk08[2048];
u32  hfar = 0;                  /* event handler (seg:off)    */

enum { RAX, RBX, RCX, RDX, RSI, RDI, RBP, RES, RDS };

/* ------------------------------------------------------------------ */
/*  timing (port 61h refresh bit toggles every ~15 us; works with       */
/*  interrupts off, so it is safe inside the timer handler)             */
/* ------------------------------------------------------------------ */

static u32 ticks(void) { return *(u32 volatile far *)0x0040006CL; }

static void udelay(u32 us)
{
    u32 n = us / 15 + 1, guard = us * 4 + 2000;
    u8 last = (u8)(inp(0x61) & 0x10), v;
    while (n && guard--) {
        v = (u8)(inp(0x61) & 0x10);
        if (v != last) { last = v; n--; }
    }
}
static void mdelay(u16 ms) { udelay((u32)ms * 1000UL); }

/* ------------------------------------------------------------------ */
/*  PCI                                                                 */
/* ------------------------------------------------------------------ */

static u16 pci_rw(u8 bus, u8 devfn, u16 reg)
{
    union REGS r;
    r.x.ax = 0xB109; r.h.bh = bus; r.h.bl = devfn; r.x.di = reg;
    int86(0x1A, &r, &r);
    return r.x.cflag ? 0xFFFF : r.x.cx;
}

static void pci_ww(u8 bus, u8 devfn, u16 reg, u16 val)
{
    union REGS r;
    r.x.ax = 0xB10C; r.h.bh = bus; r.h.bl = devfn; r.x.di = reg; r.x.cx = val;
    int86(0x1A, &r, &r);
}

/* ------------------------------------------------------------------ */
/*  UHCI schedule memory (DGROUP; physical address = DS*16 + offset)    */
/* ------------------------------------------------------------------ */

#define NCT  12                         /* control TDs           */
#define NIT  64                         /* interrupt TDs (2 x 32) */
#define HALF 32
static u8   hcmem[4096 + 4096 + 32 + 16 * NCT + 16 * NIT + 16];
static vu32 *flist, *qi, *qc, *tdc, *tdi;
static u32  ds_phys;
static u8   rep[NIT][8];
static u8   tdtog[NIT];

static u32 vphys(volatile void *p) { return ds_phys + (u16)(unsigned)p; }
static u32 phys_of(void *p)        { return ds_phys + (u16)(unsigned)p; }
#define TDC(i) (tdc + ((i) << 2))
#define TDI(i) (tdi + ((i) << 2))

#define PID_SETUP 0x2D
#define PID_IN    0x69
#define PID_OUT   0xE1
#define ST_ACTIVE  0x00800000UL
#define ST_STALL   0x00400000UL
#define ST_ERRMASK 0x00760000UL

static u16 io;
static u8  hc_bus, hc_devfn;
static int taken = 0, port = 0, lowspeed = 0;
static u16 s_cmd, s_intr, s_frnum, s_leg;
static u8  s_sof;
static u32 s_flb;

static u8  addr, ep_in, iface;
static u16 mps0, mps_in;
static int dev_ok = 0;
static int inext = 0;
static u16 errors = 0, reports = 0;
static char devname[48];

/* ------------------------------------------------------------------ */
/*  control transfers                                                   */
/* ------------------------------------------------------------------ */

static u8 setup[8];
static u8 ctlbuf[256];

static void tdc_fill(int i, u8 pid, u8 tog, u16 len, u32 buf, int spd)
{
    vu32 *t = TDC(i);
    u32 maxlen = len ? (u32)(len - 1) : 0x7FFUL;
    t[0] = vphys(TDC(i + 1)) | 4UL;
    t[1] = 0x18000000UL | ST_ACTIVE | (spd ? 0x20000000UL : 0UL) | (lowspeed ? 0x04000000UL : 0UL);
    t[2] = (maxlen << 21) | ((u32)(tog & 1) << 19) | ((u32)addr << 8) | pid;
    t[3] = buf;
}

static u16 td_act(vu32 *t) { return (u16)((t[1] + 1) & 0x7FF); }
static u16 td_max(vu32 *t) { return (u16)(((t[2] >> 21) + 1) & 0x7FF); }

static int run_ctl(int n, int *nd)
{
    u32 el, st, t0 = ticks(), spin = 0;
    int i;
    TDC(n - 1)[0] = 1UL;
    qc[1] = vphys(TDC(0));
    for (;;) {
        el = qc[1];
        if (el & 1UL) { *nd = n; return 0; }
        i = (int)(((el & ~0x0FUL) - vphys(TDC(0))) >> 4);
        if (i >= 0 && i < n) {
            st = TDC(i)[1];
            if (!(st & ST_ACTIVE)) {
                if (st & ST_ERRMASK) { qc[1] = 1UL; *nd = i; return (st & ST_STALL) ? 1 : 2; }
                if (td_act(TDC(i)) < td_max(TDC(i)) && qc[1] == el) { qc[1] = 1UL; *nd = i + 1; return 0; }
            }
        }
        if (ticks() - t0 > 18 || ++spin > 3000000UL) { qc[1] = 1UL; udelay(2000); *nd = 0; return 3; }
    }
}

static int control(u8 dev, u8 rt, u8 req, u16 val, u16 idx, u16 len, u8 *buf, u16 *got)
{
    int n = 0, nd, r, i, in = (rt & 0x80) != 0;
    u16 off = 0, chunk, total = 0;
    u8 tog = 1;
    addr = dev;
    setup[0] = rt; setup[1] = req;
    setup[2] = (u8)val; setup[3] = (u8)(val >> 8);
    setup[4] = (u8)idx; setup[5] = (u8)(idx >> 8);
    setup[6] = (u8)len; setup[7] = (u8)(len >> 8);
    tdc_fill(n++, PID_SETUP, 0, 8, phys_of(setup), 0);
    while (off < len && n < NCT) {
        chunk = len - off;
        if (chunk > mps0) chunk = mps0;
        tdc_fill(n++, (u8)(in ? PID_IN : PID_OUT), tog, chunk, phys_of(buf) + off, in);
        tog ^= 1; off += chunk;
    }
    r = run_ctl(n, &nd);
    for (i = 1; i < nd; i++) total += td_act(TDC(i));
    if (got) *got = total;
    if (r) return r;
    tdc_fill(0, (u8)((in && len) ? PID_OUT : PID_IN), 1, 0, 0UL, 0);
    return run_ctl(1, &nd);
}

/* ------------------------------------------------------------------ */
/*  interrupt IN polling: two halves of 32 TDs, refilled alternately     */
/* ------------------------------------------------------------------ */

static void tdi_fill(int i, u8 tog)
{
    vu32 *t = TDI(i);
    t[0] = (i % HALF == HALF - 1) ? 1UL : vphys(TDI(i + 1));   /* breadth first: 1 per frame */
    t[1] = 0x18000000UL | ST_ACTIVE | (lowspeed ? 0x04000000UL : 0UL);
    t[2] = ((u32)(mps_in - 1) << 21) | ((u32)(tog & 1) << 19) | ((u32)(ep_in & 0x0F) << 15) |
           ((u32)addr << 8) | PID_IN;
    t[3] = phys_of(rep[i]);
    tdtog[i] = tog;
}

static void fill_half(int h, u8 tog)
{
    int i;
    for (i = 0; i < HALF; i++) { tdi_fill(h * HALF + i, tog); tog ^= 1; }
}

static void ichain_start(void)
{
    qi[1] = 1UL;
    udelay(2000);
    fill_half(0, 0);
    fill_half(1, (u8)(tdtog[HALF - 1] ^ 1));
    TDI(HALF - 1)[0] = vphys(TDI(HALF));               /* half 0 -> half 1 */
    inext = 0;
    qi[1] = vphys(TDI(0));
}

/* half h has been used up: refill it and hang it behind the other half */
static void refill(int h)
{
    int other = h ^ 1;
    vu32 *olast = TDI(other * HALF + HALF - 1);
    fill_half(h, (u8)(tdtog[other * HALF + HALF - 1] ^ 1));
    olast[0] = vphys(TDI(h * HALF));
    if ((qi[1] & 1UL) && !(olast[1] & ST_ACTIVE))      /* controller already ran off the end */
        qi[1] = vphys(TDI(h * HALF));
}

/* ------------------------------------------------------------------ */
/*  mouse state                                                         */
/* ------------------------------------------------------------------ */

static int mx = 320, my = 100;                      /* virtual position  */
static int minx = 0, maxx = 639, miny = 0, maxy = 199;
static int hrat = 8, vrat = 16;                     /* mickeys per 8 pixels */
static long xacc = 0, yacc = 0;
static int mickx = 0, micky = 0;                    /* for function 0Bh   */
static int evx = 0, evy = 0;                        /* mickeys since last event */
static u16 buttons = 0;
static u16 presses[3], releases[3];
static int pressx[3], pressy[3], relx[3], rely[3];
static u16 hmask = 0;
static u16 pend = 0;
static int cursor_cnt = -1;                         /* visible when >= 0 */
static u16 txt_smask = 0x77FF, txt_cmask = 0x7700;
static int hotx = 0, hoty = 0;
static u16 gmask[32] = {
    0x3FFF,0x1FFF,0x0FFF,0x07FF,0x03FF,0x01FF,0x00FF,0x007F,
    0x003F,0x001F,0x01FF,0x10FF,0x30FF,0xF87F,0xF87F,0xFC7F,
    0x0000,0x4000,0x6000,0x7000,0x7800,0x7C00,0x7E00,0x7F00,
    0x7F80,0x7C00,0x6C00,0x4600,0x0600,0x0300,0x0300,0x0000 };

static void process_report(const u8 *r)
{
    int dx = (signed char)r[1], dy = (signed char)r[2], b, nb;
    u16 nbtn = (u16)(r[0] & 7);
    if (dx || dy) {
        mickx += dx; micky += dy; evx += dx; evy += dy;
        xacc += (long)dx * 8; yacc += (long)dy * 8;
        mx += (int)(xacc / hrat); xacc %= hrat;
        my += (int)(yacc / vrat); yacc %= vrat;
        if (mx < minx) mx = minx; if (mx > maxx) mx = maxx;
        if (my < miny) my = miny; if (my > maxy) my = maxy;
        pend |= 1;
    }
    for (b = 0; b < 3; b++) {
        nb = (nbtn >> b) & 1;
        if (nb && !((buttons >> b) & 1)) {
            presses[b]++; pressx[b] = mx; pressy[b] = my;
            pend |= (u16)(2 << (b * 2));
        } else if (!nb && ((buttons >> b) & 1)) {
            releases[b]++; relx[b] = mx; rely[b] = my;
            pend |= (u16)(4 << (b * 2));
        }
    }
    buttons = nbtn;
    reports++;
}

static void harvest(void)
{
    u32 st;
    int guard = 0;
    if (!dev_ok) return;
    while (guard++ < NIT) {
        st = TDI(inext)[1];
        if (st & ST_ACTIVE) break;
        if (st & ST_ERRMASK) {                       /* unplugged or confused: */
            errors++;                                /* set it up again on a  */
            qi[1] = 1UL;                             /* later timer tick      */
            dev_ok = 0;
            return;
        }
        if (td_act(TDI(inext)) >= 3) process_report(rep[inext]);
        inext = (inext + 1) % NIT;
        if (inext % HALF == 0) refill((inext / HALF) ^ 1);
    }
}

/* ------------------------------------------------------------------ */
/*  cursor drawing                                                      */
/* ------------------------------------------------------------------ */

static int drawn = 0, dmode = 0;
static u16 far *dcell;
static u16 dsave;
static int dgx, dgy;
static u8 under[16 * 16];

static u8 vmode(void) { return (u8)(*(u8 far *)0x00400049L & 0x7F); }

static void cursor_erase(void)
{
    int r, c;
    if (!drawn) return;
    if (dmode == 1) *dcell = dsave;
    else if (dmode == 2) {
        u8 far *v = (u8 far *)0xA0000000L;
        for (r = 0; r < 16; r++) for (c = 0; c < 16; c++) {
            int px = dgx + c, py = dgy + r;
            if (px >= 0 && px < 320 && py >= 0 && py < 200) v[py * 320 + px] = under[r * 16 + c];
        }
    }
    drawn = 0;
}

static void cursor_draw(void)
{
    u8 m = vmode();
    int r, c;
    if (cursor_cnt < 0) return;
    if (m <= 3 || m == 7) {
        u16 cols = *(u16 far *)0x0040004AL, pg = *(u16 far *)0x0040004EL;
        u16 seg = (u16)(m == 7 ? 0xB000 : 0xB800);
        u16 off = (u16)(pg + ((my / 8) * cols + (mx / (cols == 40 ? 16 : 8))) * 2);
        dcell = (u16 far *)(((u32)seg << 16) | off);
        dsave = *dcell;
        *dcell = (u16)((dsave & txt_smask) ^ txt_cmask);
        dmode = 1; drawn = 1;
    } else if (m == 0x13) {
        u8 far *v = (u8 far *)0xA0000000L;
        dgx = mx / 2 - hotx; dgy = my - hoty;
        for (r = 0; r < 16; r++) for (c = 0; c < 16; c++) {
            int px = dgx + c, py = dgy + r;
            u8 p;
            if (px < 0 || px >= 320 || py < 0 || py >= 200) continue;
            p = v[py * 320 + px];
            under[r * 16 + c] = p;
            if (!((gmask[r] >> (15 - c)) & 1)) p = 0;
            if ((gmask[16 + r] >> (15 - c)) & 1) p ^= 0x0F;
            v[py * 320 + px] = p;
        }
        dmode = 2; drawn = 1;
    }
}

static int lastdx = -1, lastdy = -1;

static void cursor_update(void)
{
    if (cursor_cnt < 0) { cursor_erase(); return; }
    if (drawn && mx == lastdx && my == lastdy) return;
    cursor_erase();
    cursor_draw();
    lastdx = mx; lastdy = my;
}

/* ------------------------------------------------------------------ */
/*  INT 33h                                                             */
/* ------------------------------------------------------------------ */

static u16 my_psp;
static int unload_req = 0;
static void hc_release(void);

static void set_ranges_for_mode(void)
{
    u8 m = vmode();
    minx = 0; miny = 0; maxx = 639; maxy = 199;
    if (m <= 3 || m == 7) {
        u16 cols = *(u16 far *)0x0040004AL;
        u8 rows = *(u8 far *)0x00400084L;
        if (rows < 24 || rows > 59) rows = 24;
        maxx = (cols == 40 ? 640 : cols * 8) - 1;
        maxy = (rows + 1) * 8 - 1;
    } else if (m == 0x11 || m == 0x12) maxy = 479;
    else if (m == 0x0F || m == 0x10) maxy = 349;
    mx = (maxx + 1) / 2; my = (maxy + 1) / 2;
}

static void mouse_reset(void)
{
    cursor_erase();
    cursor_cnt = -1;
    set_ranges_for_mode();
    hrat = 8; vrat = 16; xacc = yacc = 0;
    mickx = micky = 0;
    memset(presses, 0, sizeof(presses)); memset(releases, 0, sizeof(releases));
    hmask = 0; hfar = 0; pend = 0;
    txt_smask = 0x77FF; txt_cmask = 0x7700;
}

void mouse33(u16 *R)
{
    u16 ax = R[RAX], b;
    harvest();
    switch (ax) {
    case 0x00: case 0x21:
        mouse_reset();
        R[RAX] = 0xFFFF; R[RBX] = 3;
        break;
    case 0x01:
        if (cursor_cnt < 0) cursor_cnt++;
        break;
    case 0x02:
        cursor_cnt--;
        break;
    case 0x03:
        R[RBX] = buttons; R[RCX] = (u16)mx; R[RDX] = (u16)my;
        break;
    case 0x04:
        mx = (int)R[RCX]; my = (int)R[RDX];
        if (mx < minx) mx = minx; if (mx > maxx) mx = maxx;
        if (my < miny) my = miny; if (my > maxy) my = maxy;
        break;
    case 0x05: case 0x06:
        b = R[RBX] > 2 ? 0 : R[RBX];
        R[RAX] = buttons;
        if (ax == 5) { R[RBX] = presses[b];  R[RCX] = (u16)pressx[b]; R[RDX] = (u16)pressy[b]; presses[b] = 0; }
        else         { R[RBX] = releases[b]; R[RCX] = (u16)relx[b];  R[RDX] = (u16)rely[b];  releases[b] = 0; }
        break;
    case 0x07:
        minx = (int)R[RCX]; maxx = (int)R[RDX];
        if (minx > maxx) { int t = minx; minx = maxx; maxx = t; }
        if (mx < minx) mx = minx; if (mx > maxx) mx = maxx;
        break;
    case 0x08:
        miny = (int)R[RCX]; maxy = (int)R[RDX];
        if (miny > maxy) { int t = miny; miny = maxy; maxy = t; }
        if (my < miny) my = miny; if (my > maxy) my = maxy;
        break;
    case 0x09: {
        u16 far *src = (u16 far *)(((u32)R[RES] << 16) | R[RDX]);
        int i;
        cursor_erase();
        hotx = (int)R[RBX]; hoty = (int)R[RCX];
        for (i = 0; i < 32; i++) gmask[i] = src[i];
        break; }
    case 0x0A:
        if (R[RBX] == 0) { cursor_erase(); txt_smask = R[RCX]; txt_cmask = R[RDX]; }
        break;
    case 0x0B:
        R[RCX] = (u16)mickx; R[RDX] = (u16)micky; mickx = micky = 0;
        break;
    case 0x0C:
        hmask = R[RCX];
        hfar = ((u32)R[RES] << 16) | R[RDX];
        break;
    case 0x0F:
        if (R[RCX]) hrat = (int)R[RCX];
        if (R[RDX]) vrat = (int)R[RDX];
        break;
    case 0x10:                                          /* exclusion area: just hide */
        if (cursor_cnt >= 0) cursor_cnt = -1;
        break;
    case 0x14: {                                        /* swap event handlers */
        u16 om = hmask; u32 of = hfar;
        hmask = R[RCX]; hfar = ((u32)R[RES] << 16) | R[RDX];
        R[RCX] = om; R[RDX] = (u16)of; R[RES] = (u16)(of >> 16);
        break; }
    case 0x15:
        R[RBX] = 64;
        break;
    case 0x1A:
        R[RAX] = ax;
        break;
    case 0x1B:
        R[RBX] = 50; R[RCX] = 50; R[RDX] = 50;
        break;
    case 0x1D: case 0x1E:
        R[RBX] = 0;
        break;
    case 0x1F:
        R[RAX] = 0x1F;
        break;
    case 0x24:
        R[RBX] = 0x0626;                                /* report "version 6.26" */
        R[RCX] = 0x0400;                                /* PS/2 type, no IRQ */
        break;
    case 0x26:
        R[RBX] = 0; R[RCX] = (u16)maxx; R[RDX] = (u16)maxy;
        break;
    case 0xFF01:                                        /* USBMOUSE: are you there? */
        R[RAX] = 0x5553;
        R[RBX] = reports; R[RCX] = errors; R[RDX] = (u16)dev_ok;
        R[RSI] = io;                                    /* controller we own */
        break;
    case 0xFF00:                                        /* USBMOUSE: unload */
        if (remove_hooks() == 0) {
            cursor_erase();
            hc_release();
            R[RAX] = 0x5553;
            R[RBX] = my_psp;
        } else R[RAX] = 0xFFFF;
        break;
    }
    cursor_update();
}

/* ------------------------------------------------------------------ */
/*  timer tick                                                          */
/* ------------------------------------------------------------------ */

static int enumerate(int p, int verbose);
static int replug_wait = 0;

void mouse_tick(void)
{
    u16 ps;
    if (!taken) return;
    ps = inpw(io + 0x10 + port * 2);
    if (!dev_ok) {
        if (ps & 0x0002) outpw(io + 0x10 + port * 2, (u16)(ps & 0x000E));
        if (ps & 1) {
            if (++replug_wait > 4) {                    /* ~0.2 s after plug-in */
                replug_wait = 0;
                if (enumerate(port, 0) == 0) { dev_ok = 1; ichain_start(); }
            }
        } else replug_wait = 0;
        return;
    }
    if (ps & 0x0002) {                                  /* unplugged / replugged */
        outpw(io + 0x10 + port * 2, (u16)(ps & 0x000E));
        qi[1] = 1UL;
        dev_ok = 0; replug_wait = 0;
        return;
    }
    harvest();
    if (pend && (pend & hmask) && hfar) {
        u16 ev = (u16)(pend & hmask);
        int ex = evx, ey = evy;
        pend = 0; evx = evy = 0;
        call_handler(ev, buttons, (u16)mx, (u16)my, (u16)ex, (u16)ey);
    } else pend = 0;
    cursor_update();
}

/* ------------------------------------------------------------------ */
/*  controller take-over / hand-back                                    */
/* ------------------------------------------------------------------ */

static void hc_take(void)
{
    int i;
    s_cmd   = inpw(io);
    s_intr  = inpw(io + 4);
    s_frnum = inpw(io + 6);
    s_flb   = inpd32(io + 8);
    s_sof   = (u8)inp(io + 0x0C);
    s_leg   = pci_rw(hc_bus, hc_devfn, 0xC0);

    pci_ww(hc_bus, hc_devfn, 0xC0, 0x8F00);
    outpw(io, 0);
    for (i = 0; i < 20 && !(inpw(io + 2) & 0x20); i++) mdelay(1);
    outpw(io, 0x0002);
    for (i = 0; i < 50 && (inpw(io) & 0x0002); i++) mdelay(1);

    qi[0] = vphys(qc) | 2UL;             /* interrupt QH -> control QH */
    qi[1] = 1UL;
    qc[0] = 1UL;
    qc[1] = 1UL;
    for (i = 0; i < 1024; i++)            /* mouse polled every 8th frame */
        flist[i] = ((i & 7) == 0 ? vphys(qi) : vphys(qc)) | 2UL;
    outpw(io + 4, 0);
    outpw(io + 2, 0x003F);
    outpd32(io + 8, (u16)(vphys(flist) & 0xFFFF), (u16)(vphys(flist) >> 16));
    outpw(io + 6, 0);
    outp(io + 0x0C, 0x40);
    outpw(io + 0x10, 0);
    outpw(io + 0x12, 0);
    outpw(io, 0x00C1);
    taken = 1;
}

static void hc_release(void)
{
    int i;
    if (!taken) return;
    taken = 0; dev_ok = 0;
    outpw(io, 0);
    for (i = 0; i < 20 && !(inpw(io + 2) & 0x20); i++) mdelay(1);
    outpw(io, 0x0002);
    for (i = 0; i < 50 && (inpw(io) & 0x0002); i++) mdelay(1);
    outpw(io + 4, s_intr);
    outpw(io + 6, s_frnum);
    outpd32(io + 8, (u16)(s_flb & 0xFFFF), (u16)(s_flb >> 16));
    outp(io + 0x0C, s_sof);
    outpw(io + 2, 0x003F);
    pci_ww(hc_bus, hc_devfn, 0xC0, s_leg);
    outpw(io, s_cmd);
}

static int port_reset(int p)
{
    u16 sc = io + 0x10 + p * 2, s;
    int i;
    outpw(sc, 0x0200);
    mdelay(60);
    outpw(sc, 0x0000);
    mdelay(2);
    for (i = 0; i < 16; i++) {
        s = inpw(sc);
        if (!(s & 0x0001)) return -1;
        if (s & 0x000A) { outpw(sc, (u16)(s & 0x000E)); continue; }
        if (s & 0x0004) break;
        outpw(sc, 0x0004);
        mdelay(10);
    }
    s = inpw(sc);
    if (!(s & 0x0004)) return -1;
    lowspeed = (s & 0x0100) != 0;
    mdelay(20);
    return 0;
}

static void get_string(u8 idx, char *dst, int max)
{
    u16 got, i, n = 0;
    dst[0] = 0;
    if (!idx) return;
    if (control(addr, 0x80, 6, (u16)(0x0300 | idx), 0x0409, 64, ctlbuf, &got) || got < 4) return;
    for (i = 2; i + 1 < got && i < ctlbuf[0] && (int)n < max - 1; i += 2)
        dst[n++] = (char)((ctlbuf[i] >= 32 && ctlbuf[i] < 127 && !ctlbuf[i + 1]) ? ctlbuf[i] : '?');
    dst[n] = 0;
}

/* -1 failed, -2 it's a keyboard, -3 not a mouse, 0 ok */
static int enumerate(int p, int verbose)
{
    u16 got, total, off;
    u8 cfgval, *d, iman, iprod;
    int found = 0, cur = 0, kbd = 0;
    char s1[24], s2[24];

    if (port_reset(p)) return -1;
    addr = 0; mps0 = 8;
    if (control(0, 0x80, 6, 0x0100, 0, 8, ctlbuf, &got) || got < 8) return -1;
    mps0 = ctlbuf[7];
    if (mps0 != 8 && mps0 != 16 && mps0 != 32 && mps0 != 64) mps0 = 8;
    if (control(0, 0x00, 5, (u16)(p + 1), 0, 0, NULL, NULL)) return -1;
    mdelay(10);
    addr = (u8)(p + 1);
    if (control(addr, 0x80, 6, 0x0100, 0, 18, ctlbuf, &got) || got < 18) return -1;
    iman = ctlbuf[14]; iprod = ctlbuf[15];
    if (control(addr, 0x80, 6, 0x0200, 0, 9, ctlbuf, &got) || got < 9) return -1;
    total = ctlbuf[2] | (ctlbuf[3] << 8);
    if (total > sizeof(ctlbuf)) total = sizeof(ctlbuf);
    if (control(addr, 0x80, 6, 0x0200, 0, total, ctlbuf, &got)) return -1;
    total = got;
    cfgval = ctlbuf[5];
    ep_in = 0;
    for (off = 0; off + 2 <= total; off += d[0]) {
        d = ctlbuf + off;
        if (d[0] < 2) break;
        if (d[1] == 4 && d[0] >= 9) {
            if (found) break;
            cur = (d[5] == 3 && d[7] == 2);                 /* HID, mouse */
            if (d[5] == 3 && d[7] == 1) kbd = 1;            /* HID, keyboard */
            if (cur) iface = d[2];
        } else if (d[1] == 5 && d[0] >= 7 && cur) {
            if ((d[3] & 3) == 3 && (d[2] & 0x80)) {
                ep_in = d[2]; mps_in = (d[4] | (d[5] << 8)) & 0x7FF;
                found = 1;
            }
        }
    }
    if (!found) return kbd ? -2 : -3;
    if (mps_in == 0 || mps_in > 8) mps_in = 8;
    if (control(addr, 0x00, 9, cfgval, 0, 0, NULL, NULL)) return -1;
    control(addr, 0x21, 0x0B, 0, iface, 0, NULL, NULL);      /* SET_PROTOCOL: boot */
    control(addr, 0x21, 0x0A, 0, iface, 0, NULL, NULL);      /* SET_IDLE: only on change */
    if (verbose) {
        get_string(iman, s1, sizeof(s1));
        get_string(iprod, s2, sizeof(s2));
        sprintf(devname, "%s%s%s", s1, s1[0] ? " " : "", s2[0] ? s2 : "USB mouse");
    }
    return 0;
}

/* Is the BIOS polling a keyboard on this controller? Look for an
   interrupt IN transfer of 8 bytes in its schedule (keyboards send 8). */
static int bios_kbd_here(void)
{
    u32 flb = inpd32(io + 8) & ~0xFFFUL, e, a, t, tok;
    int f, depth, guard = 0;
    if (!flb) return 0;
    for (f = 0; f < 32; f++) {
        e = mrd32(flb + (u32)f * 4);
        for (depth = 0; !(e & 1UL) && depth < 24 && guard < 3000; depth++, guard++) {
            a = e & ~0x0FUL;
            if (e & 2UL) {                                   /* queue head */
                t = mrd32(a + 4);
                while (!(t & 3UL) && guard < 3000) {         /* TDs queued on it */
                    tok = mrd32((t & ~0x0FUL) + 8);
                    if ((tok & 0xFF) == PID_IN && ((tok >> 15) & 0x0F) && (((tok >> 21) + 1) & 0x7FF) == 8)
                        return 1;
                    t = mrd32(t & ~0x0FUL);
                    guard++;
                }
                e = mrd32(a);
            } else {                                         /* transfer descriptor */
                tok = mrd32(a + 8);
                if ((tok & 0xFF) == PID_IN && ((tok >> 15) & 0x0F) && (((tok >> 21) + 1) & 0x7FF) == 8)
                    return 1;
                e = mrd32(a);
            }
        }
    }
    return 0;
}

static int a20_on(void)
{
    u8 far *lo = (u8 far *)0x00000500L;
    u8 far *hi = (u8 far *)0xFFFF0510L;
    u8 a, b, ok;
    union REGS r;
    a = *lo; b = *hi; *lo = 0x5A; *hi = 0xA5; ok = (u8)(*lo == 0x5A); *lo = a; *hi = b;
    if (ok) return 1;
    r.x.ax = 0x2401; int86(0x15, &r, &r);
    a = *lo; b = *hi; *lo = 0x5A; *hi = 0xA5; ok = (u8)(*lo == 0x5A); *lo = a; *hi = b;
    return ok;
}

/* ------------------------------------------------------------------ */
/*  install / unload                                                    */
/* ------------------------------------------------------------------ */

static int find_mouse(int want)
{
    union REGS r;
    u16 bus, dev, fn, vid, ps[2];
    u8 devfn, last;
    int k = 0, p, e, peek;

    r.x.ax = 0xB101; r.x.di = 0;
    int86(0x1A, &r, &r);
    if (r.x.cflag || r.h.ah != 0 || r.x.dx != 0x4350) { printf("No PCI BIOS.\n"); return -1; }
    last = r.h.cl;
    peek = a20_on() && unreal_on() == 0;

    for (bus = 0; bus <= last; bus++)
    for (dev = 0; dev < 32; dev++)
    for (fn = 0; fn < 8; fn++) {
        devfn = (u8)((dev << 3) | fn);
        vid = pci_rw((u8)bus, devfn, 0);
        if (vid == 0xFFFF || vid == 0) { if (fn == 0) break; continue; }
        if (pci_rw((u8)bus, devfn, 0x0A) != 0x0C03) continue;
        if ((pci_rw((u8)bus, devfn, 0x08) >> 8) != 0x00) continue;
        k++;
        if (want && k != want) continue;
        io = pci_rw((u8)bus, devfn, 0x20) & 0xFFE0;
        if (!io) continue;
        hc_bus = (u8)bus; hc_devfn = devfn;
        ps[0] = inpw(io + 0x10); ps[1] = inpw(io + 0x12);
        if (!(ps[0] & 1) && !(ps[1] & 1)) continue;
        if (!want && peek && bios_kbd_here()) {
            printf("  USB controller %d: the BIOS is using a keyboard here - leaving it alone\n", k);
            continue;
        }
        hc_take();
        for (p = 0; p < 2; p++) {
            if (!(inpw(io + 0x10 + p * 2) & 1)) continue;
            e = enumerate(p, 1);
            if (e == 0) {
                port = p;
                printf("  USB controller %d (%02X:%02X.%X) port %d: %s\n", k, bus, dev, fn, p + 1, devname);
                return 0;
            }
            outpw(io + 0x10 + p * 2, 0);
            if (e == -2) {
                printf("  USB controller %d: that's the keyboard - giving the controller back\n", k);
                break;
            }
        }
        hc_release();
    }
    return -1;
}

int main(int argc, char **argv)
{
    union REGS r;
    struct SREGS s;
    int i, want = 0, unload = 0;
    u32 base, al;
    u16 sp_now, paras, envseg;

    for (i = 1; i < argc; i++) {
        char *a = argv[i];
        if (a[0] == '/' || a[0] == '-') {
            if (a[1] == 'u' || a[1] == 'U') unload = 1;
            else if ((a[1] == 'c' || a[1] == 'C') && a[2] == ':') want = atoi(a + 3);
            else {
                printf("USBMOUSE " VERSION " - USB mouse driver (INT 33h) for DOS\n"
                       "  USBMOUSE        find the USB mouse and load\n"
                       "  USBMOUSE /C:n   use USB 1.1 controller n\n"
                       "  USBMOUSE /U     unload\n");
                return 0;
            }
        }
    }

    /* already loaded? */
    r.x.ax = 0xFF01; r.x.bx = r.x.cx = r.x.dx = 0;
    if (*(u32 far *)(0x33L * 4)) int86(0x33, &r, &r); else r.x.ax = 0;
    if (unload) {
        if (r.x.ax != 0x5553) { printf("USBMOUSE isn't loaded.\n"); return 1; }
        r.x.ax = 0xFF00; int86(0x33, &r, &r);
        if (r.x.ax != 0x5553) { printf("Can't unload: another program hooked INT 33h/08h after USBMOUSE.\n"); return 1; }
        _dos_freemem(r.x.bx);
        printf("USBMOUSE unloaded, USB controller given back to the BIOS.\n");
        return 0;
    }
    if (r.x.ax == 0x5553) {
        printf("USBMOUSE is already loaded (%u reports so far, mouse %s).\n",
               r.x.bx, r.x.dx ? "connected" : "not connected");
        return 0;
    }

    printf("USBMOUSE " VERSION " - looking for a USB mouse...\n");
    segread(&s);
    ds_phys = (u32)s.ds << 4;
    base = phys_of(hcmem);
    al = (base + 4095UL) & ~4095UL;
    flist = (vu32 *)(hcmem + (u16)(al - base));
    qi = flist + 1024;
    qc = qi + 4;
    tdc = qc + 4;
    tdi = tdc + 4 * NCT;

    if (find_mouse(want)) {
        printf("No USB mouse found.\n"
               "  Plug it into a USB port that isn't on the keyboard's controller\n"
               "  (try a different pair of ports), then run USBMOUSE again.\n");
        return 1;
    }
    dev_ok = 1;
    ichain_start();
    mouse_reset();
    my_psp = _psp;
    install_hooks();
    printf("USBMOUSE loaded. INT 33h is ready.\n");

    /* free the environment, stay resident up to the top of our stack */
    envseg = *(u16 far *)(((u32)_psp << 16) | 0x2C);
    if (envseg) _dos_freemem(envseg);
    _asm mov sp_now, sp
    paras = (u16)(s.ds - _psp) + (u16)((sp_now + 256u + 15u) >> 4);
    _dos_keep(0, paras);
    return 0;
}

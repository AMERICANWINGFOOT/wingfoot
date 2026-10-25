/*
 *  USBDRV.C - direct USB driver for USB sticks under DOS (real mode)
 *
 *  For PCs whose BIOS doesn't offer USB sticks as a disk.
 *    UHCI (USB 1.1): programmed through I/O ports, ~0.8 MB/s
 *    EHCI (USB 2.0): registers are memory-mapped above 1 MB, reached in
 *                    "unreal mode" (FS with a 4 GB limit), ~15-25 MB/s
 *  Both share the same USB Mass Storage (bulk-only) + SCSI layer.
 *  Polling only, no IRQs. All DMA memory lives in DGROUP, whose
 *  physical address is DS*16 (real mode, no EMM386).
 *  usb_close() hands the controller back to the BIOS.
 *
 *  Needs IO32.OBJ (32-bit port I/O, unreal mode, flat memory access).
 */

#include <stdio.h>
#include <string.h>
#include <dos.h>
#include <conio.h>
#include "USBDRV.H"

typedef unsigned char  u8;
typedef unsigned int   u16;
typedef unsigned long  u32;
typedef volatile unsigned long vu32;

extern void outpd32(unsigned port, unsigned lo, unsigned hi);
extern unsigned long inpd32(unsigned port);
extern int  unreal_on(void);
extern unsigned long mrd32(unsigned long a);
extern void mwr32(unsigned long a, unsigned long v);

char usb_name[48];
char usb_where[40];
char usb_err[80];

/* ---------------- DMA memory (shared by UHCI and EHCI) ---------------- */

#define NTD   264                         /* UHCI: 256 x 64 bytes = 16 KB per batch */
static u8   hcmem[4096 + 4096 + 16 * (NTD + 2)];
static vu32 *flist, *qh, *tdp;            /* UHCI frame list, QH, TDs */
static u32  ds_phys, td0_phys, mem4k;     /* mem4k: 4 KB aligned base */
static vu32 *mem4k_p;

static u32 phys_of(const void *p) { return ds_phys + (u16)(unsigned)p; }
static u32 vphys(vu32 *p)         { return ds_phys + (u16)(unsigned)p; }
#define TD(i)     (tdp + ((i) << 2))
#define TDPHYS(i) (td0_phys + ((u32)(i) << 4))

/* ---------------- shared device state ---------------- */

static int hc_type = 0;                   /* 1 = UHCI, 2 = EHCI */
static int taken = 0, lowspeed = 0, portno = 0;
static u8  hc_bus, hc_devfn;

static u8  addr;                          /* current device address */
static u16 mps0;
static u8  ep_in, ep_out, iface;
static u16 mps_in, mps_out;
static u8  tog_in, tog_out;
static u32 tag = 0x1000;
static u32 nsect;

static u8  setup[8];
static u8  cbw[32], csw[16];
static u8  ctlbuf[256];
static u8  sense[20];

/* ---------------- small helpers ---------------- */

static u16 rd16(const u8 *p) { return (u16)(p[0] | ((u16)p[1] << 8)); }
static u32 be32(const u8 *p) { return ((u32)p[0] << 24) | ((u32)p[1] << 16) | ((u32)p[2] << 8) | p[3]; }

static u32 ticks(void) { return *(u32 volatile far *)0x0040006CL; }

static void delay_ms(u16 ms)
{
    union REGS r;
    u32 us = (u32)ms * 1000UL;
    r.h.ah = 0x86;
    r.x.cx = (u16)(us >> 16);
    r.x.dx = (u16)(us & 0xFFFF);
    int86(0x15, &r, &r);
    if (r.x.cflag) {                      /* no INT 15h wait: use the 18.2 Hz tick */
        u32 t0 = ticks(), n = ms / 55 + 2;
        while (ticks() - t0 < n) ;
    }
}

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

static u32 pci_rd(u8 bus, u8 devfn, u16 reg)
{
    return (u32)pci_rw(bus, devfn, reg) | ((u32)pci_rw(bus, devfn, reg + 2) << 16);
}

static int  control(u8 dev, u8 rt, u8 req, u16 val, u16 idx, u16 len, u8 *buf, u16 *got);
static int  bulk(int in, u32 phys, u32 len, u32 *got);
static void e_set_bulk(void);

/* ====================================================================== */
/*  UHCI                                                                  */
/* ====================================================================== */

#define PID_SETUP 0x2D
#define PID_IN    0x69
#define PID_OUT   0xE1

#define ST_ACTIVE  0x00800000UL
#define ST_STALL   0x00400000UL
#define ST_ERRMASK 0x00760000UL           /* stall, DBE, babble, CRC/timeout, bitstuff */

static u16 io;                            /* UHCI I/O base */
static u16 s_cmd, s_intr, s_frnum, s_leg;
static u8  s_sof;
static u32 s_flb;

static void td_fill(int i, u8 pid, u8 tog, u8 ep, u16 len, u32 buf, int spd)
{
    vu32 *t = TD(i);
    u32 maxlen = len ? (u32)(len - 1) : 0x7FFUL;
    t[0] = TDPHYS(i + 1) | 4UL;           /* depth first: next TD in the same frame */
    t[1] = 0x18000000UL | ST_ACTIVE | (spd ? 0x20000000UL : 0UL) | (lowspeed ? 0x04000000UL : 0UL);
    t[2] = (maxlen << 21) | ((u32)(tog & 1) << 19) | ((u32)(ep & 0x0F) << 15) |
           ((u32)addr << 8) | pid;
    t[3] = buf;
}

static u16 td_actlen(int i) { return (u16)((TD(i)[1] + 1) & 0x7FF); }
static u16 td_maxlen(int i) { return (u16)(((TD(i)[2] >> 21) + 1) & 0x7FF); }

/* Run TDs 0..n-1. Returns 0 ok, 1 stall, 2 error, 3 timeout.
   *nd = number of TDs that completed (a short packet counts and ends the run). */
static int run(int n, u16 tmo, int *nd)
{
    u32 el, st, t0;
    int i;

    TD(n - 1)[0] = 1UL;                   /* terminate */
    qh[1] = TDPHYS(0);
    t0 = ticks();
    for (;;) {
        el = qh[1];
        if (el & 1UL) { *nd = n; return 0; }
        i = (int)(((el & ~0x0FUL) - td0_phys) >> 4);
        if (i >= 0 && i < n) {
            st = TD(i)[1];
            if (!(st & ST_ACTIVE)) {
                if (st & ST_ERRMASK) {
                    qh[1] = 1UL;
                    *nd = i;
                    return (st & ST_STALL) ? 1 : 2;
                }
                /* inactive, no error, queue not advanced: short packet */
                if (td_actlen(i) < td_maxlen(i) && qh[1] == el) {
                    qh[1] = 1UL;
                    *nd = i + 1;
                    return 0;
                }
            }
        }
        if (ticks() - t0 > tmo) {
            qh[1] = 1UL;
            delay_ms(2);
            for (i = 0; i < n; i++) {
                st = TD(i)[1];
                if ((st & ST_ACTIVE) || (st & ST_ERRMASK)) break;
            }
            *nd = i;
            return 3;
        }
    }
}

static int u_control(u8 dev, u8 rt, u8 req, u16 val, u16 idx, u16 len, u8 *buf, u16 *got)
{
    int n = 0, nd, r, i, in = (rt & 0x80) != 0;
    u16 off = 0, chunk, total = 0;
    u8 tog = 1;

    addr = dev;
    td_fill(n++, PID_SETUP, 0, 0, 8, phys_of(setup), 0);
    while (off < len && n < NTD) {
        chunk = len - off;
        if (chunk > mps0) chunk = mps0;
        td_fill(n++, (u8)(in ? PID_IN : PID_OUT), tog, 0, chunk, phys_of(buf) + off, in);
        tog ^= 1; off += chunk;
    }
    r = run(n, 55, &nd);
    for (i = 1; i < nd; i++) total += td_actlen(i);
    if (got) *got = total;
    if (r) return r;
    /* status stage, opposite direction, always DATA1 */
    td_fill(0, (u8)((in && len) ? PID_OUT : PID_IN), 1, 0, 0, 0UL, 0);
    return run(1, 55, &nd);
}

static int u_bulk(int in, u32 phys, u32 len, u32 *got)
{
    u8  ep = in ? ep_in : ep_out;
    u16 mps = in ? mps_in : mps_out;
    u8  tog = in ? tog_in : tog_out, tog0;
    u32 total = 0;
    int n, nd, r = 0, i;
    u16 chunk;

    while (len) {
        n = 0; tog0 = tog;
        while (len && n < NTD) {
            chunk = len > mps ? mps : (u16)len;
            td_fill(n++, (u8)(in ? PID_IN : PID_OUT), tog, ep, chunk, phys, in);
            tog ^= 1; phys += chunk; len -= chunk;
        }
        r = run(n, 91, &nd);              /* 5 s: flash writes can NAK a while */
        for (i = 0; i < nd; i++) total += td_actlen(i);
        tog = (u8)(tog0 ^ (nd & 1));
        if (r || nd < n) break;
    }
    if (in) tog_in = tog; else tog_out = tog;
    if (got) *got = total;
    return r;
}

static void u_take(void)
{
    int i;
    s_cmd   = inpw(io);
    s_intr  = inpw(io + 4);
    s_frnum = inpw(io + 6);
    s_flb   = inpd32(io + 8);
    s_sof   = (u8)inp(io + 0x0C);
    s_leg   = pci_rw(hc_bus, hc_devfn, 0xC0);

    pci_ww(hc_bus, hc_devfn, 0xC0, 0x8F00);          /* BIOS SMI + traps off, clear status */
    outpw(io, 0);                                     /* stop */
    for (i = 0; i < 20 && !(inpw(io + 2) & 0x20); i++) delay_ms(1);
    outpw(io, 0x0002);                                /* host controller reset */
    for (i = 0; i < 50 && (inpw(io) & 0x0002); i++) delay_ms(1);

    for (i = 0; i < 1024; i++) flist[i] = vphys(qh) | 2UL;   /* every frame -> QH */
    qh[0] = 1UL;
    qh[1] = 1UL;
    outpw(io + 4, 0);                                 /* no interrupts, we poll */
    outpw(io + 2, 0x003F);
    outpd32(io + 8, (u16)(vphys(flist) & 0xFFFF), (u16)(vphys(flist) >> 16));
    outpw(io + 6, 0);
    outp(io + 0x0C, 0x40);
    outpw(io + 0x10, 0);                              /* both ports disabled until reset */
    outpw(io + 0x12, 0);
    outpw(io, 0x00C1);                                /* run, configured, 64-byte packets */
    taken = 1;
    hc_type = 1;
}

static void u_close(void)
{
    int i;
    outpw(io, 0);
    for (i = 0; i < 20 && !(inpw(io + 2) & 0x20); i++) delay_ms(1);
    outpw(io, 0x0002);
    for (i = 0; i < 50 && (inpw(io) & 0x0002); i++) delay_ms(1);
    outpw(io + 4, s_intr);
    outpw(io + 6, s_frnum);
    outpd32(io + 8, (u16)(s_flb & 0xFFFF), (u16)(s_flb >> 16));
    outp(io + 0x0C, s_sof);
    outpw(io + 2, 0x003F);
    pci_ww(hc_bus, hc_devfn, 0xC0, s_leg);           /* give it back to the BIOS */
    outpw(io, s_cmd);
}

static int u_port_reset(int p)
{
    u16 sc = io + 0x10 + p * 2, s;
    int i;

    outpw(sc, 0x0200);                                /* reset on */
    delay_ms(60);
    outpw(sc, 0x0000);
    delay_ms(2);
    for (i = 0; i < 16; i++) {
        s = inpw(sc);
        if (!(s & 0x0001)) return -1;                 /* nothing connected */
        if (s & 0x000A) { outpw(sc, (u16)(s & 0x000E)); continue; }   /* clear change bits */
        if (s & 0x0004) break;
        outpw(sc, 0x0004);                            /* enable */
        delay_ms(10);
    }
    s = inpw(sc);
    if (!(s & 0x0004)) return -1;
    lowspeed = (s & 0x0100) != 0;
    delay_ms(20);
    return 0;
}

/* ====================================================================== */
/*  EHCI                                                                  */
/* ====================================================================== */

/* operational register offsets */
#define E_CMD     0x00
#define E_STS     0x04
#define E_INTR    0x08
#define E_CTRLDS  0x10
#define E_PERIOD  0x14
#define E_ASYNC   0x18
#define E_CF      0x40
#define E_PORT(p) (0x44 + 4 * (p))

/* qTD token bits */
#define QT_ACTIVE 0x80UL
#define QT_HALT   0x40UL
#define QT_ERRS   0x38UL                  /* data buffer error, babble, transaction error */

static u32 e_base, e_op, e_hcs, e_hcc;
static int e_nports, e_eecp;
static u32 s_ecmd, s_eintr, s_easync, s_eper, s_ectrlds, s_ecf, s_elegc, s_elegs;
static int e_cf_changed = 0;
static u8  e_q0dev = 0xFF;
static u16 e_qlen[8];

/* 3 QHs (control, bulk IN, bulk OUT) at mem4k+0/128/256, 8 qTDs at +512 */
#define EQH(n)      (mem4k_p + (n) * 32)
#define EQHPHYS(n)  (mem4k + (u32)(n) * 128UL)
#define QTD(i)      (mem4k_p + 128 + (i) * 16)
#define QTDPHYS(i)  (mem4k + 512UL + (u32)(i) * 64UL)

static u32  er(u16 off)         { return mrd32(e_op + off); }
static void ew(u16 off, u32 v)  { mwr32(e_op + off, v); }

static int a20_ok(void)
{
    u8 far *lo = (u8 far *)0x00000500L;
    u8 far *hi = (u8 far *)0xFFFF0510L;
    u8 a = *lo, b = *hi, ok;
    *lo = 0x5A; *hi = 0xA5;
    ok = (u8)(*lo == 0x5A);
    *lo = a; *hi = b;
    return ok;
}

static void a20_on(void)
{
    union REGS r;
    if (a20_ok()) return;
    r.x.ax = 0x2401; int86(0x15, &r, &r);            /* BIOS: enable A20 */
    if (a20_ok()) return;
    outp(0x92, (inp(0x92) | 2) & 0xFE);               /* "fast A20" port */
}

static void e_async(int on)
{
    u32 c = er(E_CMD);
    int i;
    if (on) ew(E_CMD, c | 0x20UL); else ew(E_CMD, c & ~0x20UL);
    for (i = 0; i < 100; i++) {
        if (((er(E_STS) & 0x8000UL) != 0) == (on != 0)) break;
        delay_ms(1);
    }
}

static void e_qh_set(int n, u8 dev, u8 ep, u16 mps)
{
    vu32 *q = EQH(n);
    int i;
    q[0] = EQHPHYS((n + 1) % 3) | 2UL;                /* ring of 3 QHs */
    q[1] = ((u32)mps << 16) | (n == 0 ? 0x8000UL : 0UL) | 0x4000UL |  /* H, DTC */
           (2UL << 12) | ((u32)(ep & 0x0F) << 8) | dev;              /* high speed */
    q[2] = 1UL << 30;                                 /* one transaction per microframe */
    q[3] = 0;
    q[4] = 1UL;                                       /* next qTD: none */
    q[5] = 1UL;
    for (i = 6; i < 17; i++) q[i] = 0;
}

static void e_qh_idle(int n)
{
    vu32 *q = EQH(n);
    q[6] = 0;                                         /* clear halt / active */
    q[4] = 1UL;
    q[5] = 1UL;
}

static void e_qtd(int i, int last, u8 pid, u8 tog, u32 buf, u16 len)
{
    vu32 *t = QTD(i);
    int k;
    t[0] = last ? 1UL : QTDPHYS(i + 1);
    t[1] = 1UL;                                       /* short packet: stop */
    t[3] = buf;
    for (k = 1; k < 5; k++) t[3 + k] = (buf & ~0xFFFUL) + 0x1000UL * k;
    for (k = 8; k < 13; k++) t[k] = 0;
    t[2] = ((u32)(tog & 1) << 31) | ((u32)len << 16) | (3UL << 10) | ((u32)pid << 8) | QT_ACTIVE;
    e_qlen[i] = len;
}

/* Run qTDs 0..n-1 on QH 'qn'. Returns 0 ok, 1 stall, 2 error, 3 timeout.
   *bytes = data moved, *ntog = data toggle after the last packet. */
static int e_run(int qn, int n, int in, u16 tmo, u32 *bytes, u8 *ntog)
{
    vu32 *q = EQH(qn);
    u32 tok, t0, total;
    int i, state, k;

    q[4] = QTDPHYS(0);                                /* hand the chain to the controller */
    t0 = ticks();
    for (;;) {
        state = 0; total = 0;                         /* 0 running, 1 done, 2 stall, 3 error */
        for (i = 0; i < n; i++) {
            tok = QTD(i)[2];
            if (tok & QT_ACTIVE) { state = 0; break; }
            total += e_qlen[i] - ((tok >> 16) & 0x7FFF);
            *ntog = (u8)(tok >> 31);
            if (tok & QT_HALT) { state = (tok & QT_ERRS) ? 3 : 2; break; }
            if (in && ((tok >> 16) & 0x7FFF)) { state = 1; break; }   /* short packet */
            if (i == n - 1) state = 1;
        }
        if (state) break;
        if (ticks() - t0 > tmo) { state = 4; break; }
    }
    *bytes = total;
    if (state == 1) {
        for (k = 0; k < 1000 && (q[6] & QT_ACTIVE); k++) ;   /* overlay written back */
        return 0;
    }
    /* error or timeout: pull the queue out from under the controller */
    e_async(0);
    e_qh_idle(qn);
    for (i = 0; i < n; i++) QTD(i)[2] &= ~QT_ACTIVE;
    e_async(1);
    return state == 2 ? 1 : (state == 3 ? 2 : 3);
}

static int e_control(u8 dev, u8 rt, u8 req, u16 val, u16 idx, u16 len, u8 *buf, u16 *got)
{
    int in = (rt & 0x80) != 0, n = 0, r;
    u32 bytes;
    u8 tog;

    addr = dev;
    if (dev != e_q0dev) {                             /* QH 0 must know the address */
        e_async(0);
        e_qh_set(0, dev, 0, mps0);
        e_async(1);
        e_q0dev = dev;
    }
    e_qtd(n++, len == 0, 2, 0, phys_of(setup), 8);
    if (len) e_qtd(n++, 1, (u8)(in ? 1 : 0), 1, phys_of(buf), len);
    r = e_run(0, n, in, 55, &bytes, &tog);
    if (got) *got = bytes >= 8 ? (u16)(bytes - 8) : 0;
    if (r) return r;
    e_qtd(0, 1, (u8)((in && len) ? 0 : 1), 1, 0UL, 0);   /* status stage */
    return e_run(0, 1, 0, 55, &bytes, &tog);
}

static int e_bulk(int in, u32 phys, u32 len, u32 *got)
{
    u32 total = 0, bytes;
    u16 chunk;
    u8 tog = in ? tog_in : tog_out;
    int r = 0;

    while (len) {
        chunk = len > 16384UL ? 16384 : (u16)len;     /* one qTD carries up to 16 KB */
        e_qtd(0, 1, (u8)(in ? 1 : 0), tog, phys, chunk);
        r = e_run(in ? 1 : 2, 1, in, 91, &bytes, &tog);
        total += bytes;
        if (r || bytes < chunk) break;
        phys += chunk; len -= chunk;
    }
    if (in) tog_in = tog; else tog_out = tog;
    if (got) *got = total;
    return r;
}

static void e_set_bulk(void)
{
    if (hc_type != 2) return;
    e_async(0);
    e_qh_set(1, addr, ep_in, mps_in);
    e_qh_set(2, addr, ep_out, mps_out);
    e_async(1);
}

/* flags: 2 = may switch the ports over to USB 2.0, 4 = test: act as if the BIOS left them on USB 1.1 */
static int e_take(int flags)
{
    u16 w;
    int i;

    a20_on();
    if (unreal_on()) { strcpy(usb_err, "USB 2.0 needs plain DOS (EMM386/Windows is running)"); return -1; }
    w = pci_rw(hc_bus, hc_devfn, 4);
    pci_ww(hc_bus, hc_devfn, 4, (u16)(w | 6));      /* memory space + bus master */
    e_op  = e_base + (mrd32(e_base) & 0xFF);
    e_hcs = mrd32(e_base + 4);
    e_hcc = mrd32(e_base + 8);
    e_nports = (int)(e_hcs & 0x0F);
    if (flags & 4) { ew(E_CMD, er(E_CMD) & ~0x31UL); delay_ms(5); ew(E_CF, 0); delay_ms(20); }
    s_ecf = er(E_CF) & 1UL;
    if (!s_ecf && !(flags & 2)) return -1;           /* ports belong to USB 1.1: leave alone */

    /* BIOS hand-off (USBLEGSUP) */
    e_eecp = (int)((e_hcc >> 8) & 0xFF);
    s_elegs = s_elegc = 0;
    if (e_eecp >= 0x40) {
        s_elegs = pci_rd(hc_bus, hc_devfn, (u16)e_eecp);
        if ((s_elegs & 0xFF) == 1) {
            s_elegc = pci_rd(hc_bus, hc_devfn, (u16)(e_eecp + 4));
            pci_ww(hc_bus, hc_devfn, (u16)(e_eecp + 2), (u16)((s_elegs >> 16) | 0x100));
            for (i = 0; i < 100 && (pci_rw(hc_bus, hc_devfn, (u16)(e_eecp + 2)) & 1); i++) delay_ms(10);
            pci_ww(hc_bus, hc_devfn, (u16)(e_eecp + 4), 0);
            pci_ww(hc_bus, hc_devfn, (u16)(e_eecp + 6), 0xE000);
        } else e_eecp = 0;
    } else e_eecp = 0;

    s_ecmd = er(E_CMD); s_eintr = er(E_INTR); s_easync = er(E_ASYNC);
    s_eper = er(E_PERIOD); s_ectrlds = er(E_CTRLDS);

    ew(E_INTR, 0);
    ew(E_CMD, s_ecmd & ~0x31UL);                      /* stop, schedules off */
    for (i = 0; i < 20 && !(er(E_STS) & 0x1000UL); i++) delay_ms(1);
    if (e_hcc & 1) ew(E_CTRLDS, 0);                   /* 64-bit capable: our memory is < 4 GB */

    e_q0dev = 0xFF;
    e_qh_set(0, 0, 0, 64);
    e_qh_set(1, 0, 1, 512);
    e_qh_set(2, 0, 2, 512);
    ew(E_ASYNC, EQHPHYS(0));
    ew(E_STS, 0x3FUL);
    ew(E_CMD, (1UL << 16) | 0x21UL);                  /* run, async schedule on */
    for (i = 0; i < 20 && (er(E_STS) & 0x1000UL); i++) delay_ms(1);
    e_async(1);

    e_cf_changed = 0;
    if (!s_ecf) { ew(E_CF, 1UL); e_cf_changed = 1; }
    if (e_hcs & 0x10)                                 /* port power control */
        for (i = 0; i < e_nports; i++)
            ew((u16)E_PORT(i), (er((u16)E_PORT(i)) & ~0x2AUL) | 0x1000UL);
    if (e_cf_changed) delay_ms(150);
    taken = 1;
    hc_type = 2;
    return 0;
}

static void e_close(void)
{
    int i;
    e_async(0);
    ew(E_CMD, er(E_CMD) & ~0x31UL);
    for (i = 0; i < 20 && !(er(E_STS) & 0x1000UL); i++) delay_ms(1);
    if (e_cf_changed) ew(E_CF, 0);                    /* ports back to USB 1.1 */
    ew(E_ASYNC, s_easync);
    ew(E_PERIOD, s_eper);
    if (e_hcc & 1) ew(E_CTRLDS, s_ectrlds);
    ew(E_STS, 0x3FUL);
    ew(E_INTR, s_eintr);
    ew(E_CMD, s_ecmd);
    if (e_eecp) {
        pci_ww(hc_bus, hc_devfn, (u16)(e_eecp + 4), (u16)(s_elegc & 0xFFFF));
        pci_ww(hc_bus, hc_devfn, (u16)(e_eecp + 6), (u16)(s_elegc >> 16));
        pci_ww(hc_bus, hc_devfn, (u16)(e_eecp + 2), (u16)(s_elegs >> 16));
    }
}

/* Reset port p. Returns 0 = high-speed device ready, 1 = not ours (handed to USB 1.1), -1 = nothing */
static int e_port_reset(int p)
{
    u16 pr = (u16)E_PORT(p);
    u32 s;
    int i;

    s = er(pr);
    if (!(s & 1UL)) return -1;
    if (s & 0x2000UL) return 1;                       /* already owned by USB 1.1 */
    if (((s >> 10) & 3) == 1) {                       /* low-speed: give to the companion */
        ew(pr, (s & ~0x2AUL) | 0x2000UL);
        return 1;
    }
    ew(pr, (s & ~0x2EUL) | 0x100UL);                  /* reset, enable bit clear */
    delay_ms(55);
    ew(pr, er(pr) & ~0x12AUL);
    for (i = 0; i < 10 && (er(pr) & 0x100UL); i++) delay_ms(1);
    delay_ms(5);
    s = er(pr);
    if (!(s & 4UL)) {                                 /* full-speed: companion's job */
        ew(pr, (s & ~0x2AUL) | 0x2000UL);
        return 1;
    }
    delay_ms(20);
    return 0;
}

/* ====================================================================== */
/*  Shared: dispatch, Bulk-Only Transport, enumeration                    */
/* ====================================================================== */

static int control(u8 dev, u8 rt, u8 req, u16 val, u16 idx, u16 len, u8 *buf, u16 *got)
{
    setup[0] = rt; setup[1] = req;
    setup[2] = (u8)val; setup[3] = (u8)(val >> 8);
    setup[4] = (u8)idx; setup[5] = (u8)(idx >> 8);
    setup[6] = (u8)len; setup[7] = (u8)(len >> 8);
    if (hc_type == 2) return e_control(dev, rt, req, val, idx, len, buf, got);
    return u_control(dev, rt, req, val, idx, len, buf, got);
}

static int bulk(int in, u32 phys, u32 len, u32 *got)
{
    if (hc_type == 2) return e_bulk(in, phys, len, got);
    return u_bulk(in, phys, len, got);
}

static int clear_halt(u8 ep)
{
    if (ep & 0x80) tog_in = 0; else tog_out = 0;
    return control(addr, 0x02, 0x01, 0, ep, 0, NULL, NULL);
}

static void reset_recovery(void)
{
    control(addr, 0x21, 0xFF, 0, iface, 0, NULL, NULL);   /* Bulk-Only Mass Storage Reset */
    delay_ms(10);
    clear_halt(ep_in);
    clear_halt(ep_out);
}

/* One SCSI command over Bulk-Only Transport.
   Returns 0 good, 1 command failed (check condition), -1 transport error */
static int bot(const u8 *cb, u8 cblen, int in, u32 phys, u32 len)
{
    u32 got;
    int r;

    memset(cbw, 0, 31);
    cbw[0] = 'U'; cbw[1] = 'S'; cbw[2] = 'B'; cbw[3] = 'C';
    tag++;
    cbw[4] = (u8)tag; cbw[5] = (u8)(tag >> 8); cbw[6] = (u8)(tag >> 16); cbw[7] = (u8)(tag >> 24);
    cbw[8] = (u8)len; cbw[9] = (u8)(len >> 8); cbw[10] = (u8)(len >> 16); cbw[11] = (u8)(len >> 24);
    cbw[12] = (u8)(in ? 0x80 : 0x00);
    cbw[13] = 0;                          /* LUN 0 */
    cbw[14] = cblen;
    memcpy(cbw + 15, cb, cblen);

    r = bulk(0, phys_of(cbw), 31, &got);
    if (r) { reset_recovery(); return -1; }
    if (len) {
        r = bulk(in, phys, len, &got);
        if (r == 1) clear_halt((u8)(in ? ep_in : ep_out));
        else if (r) { reset_recovery(); return -1; }
    }
    r = bulk(1, phys_of(csw), 13, &got);
    if (r == 1) { clear_halt(ep_in); r = bulk(1, phys_of(csw), 13, &got); }
    if (r || got != 13 || csw[0] != 'U' || csw[1] != 'S' || csw[2] != 'B' || csw[3] != 'S' ||
        memcmp(csw + 4, cbw + 4, 4)) {
        reset_recovery();
        return -1;
    }
    if (csw[12] == 0) return 0;
    if (csw[12] == 1) return 1;
    reset_recovery();
    return -1;
}

static int request_sense(void)
{
    u8 cb[6];
    memset(cb, 0, 6); cb[0] = 0x03; cb[4] = 18;
    return bot(cb, 6, 1, phys_of(sense), 18);
}

static void copy_trim(char *dst, const u8 *src, int n)
{
    int i;
    for (i = 0; i < n; i++) dst[i] = (char)((src[i] >= 32 && src[i] < 127) ? src[i] : ' ');
    dst[n] = 0;
    while (n > 0 && dst[n - 1] == ' ') dst[--n] = 0;
}

/* Port is reset and the device is at address 0. Bring it up as address 'me'. */
static int enumerate(u8 me, int verbose)
{
    u16 got, total, off;
    u8 cfgval, *d, cb[12];
    int r, i, found = 0, cur_ok = 0;

    mps0 = (u16)(hc_type == 2 ? 64 : 8);
    if (control(0, 0x80, 6, 0x0100, 0, 8, ctlbuf, &got) || got < 8) {
        strcpy(usb_err, "device doesn't answer (GET_DESCRIPTOR)"); return -1;
    }
    mps0 = ctlbuf[7];
    if (mps0 != 8 && mps0 != 16 && mps0 != 32 && mps0 != 64) mps0 = 8;
    if (control(0, 0x00, 5, me, 0, 0, NULL, NULL)) { strcpy(usb_err, "SET_ADDRESS failed"); return -1; }
    delay_ms(10);
    addr = me;
    if (control(me, 0x80, 6, 0x0100, 0, 18, ctlbuf, &got) || got < 18) {
        strcpy(usb_err, "device descriptor read failed"); return -1;
    }
    if (control(me, 0x80, 6, 0x0200, 0, 9, ctlbuf, &got) || got < 9) {
        strcpy(usb_err, "config descriptor read failed"); return -1;
    }
    total = rd16(ctlbuf + 2);
    if (total > sizeof(ctlbuf)) total = sizeof(ctlbuf);
    if (control(me, 0x80, 6, 0x0200, 0, total, ctlbuf, &got)) {
        strcpy(usb_err, "config descriptor read failed"); return -1;
    }
    total = got;
    cfgval = ctlbuf[5];

    ep_in = ep_out = 0;
    for (off = 0; off + 2 <= total; off += d[0]) {
        d = ctlbuf + off;
        if (d[0] < 2) break;
        if (d[1] == 4 && d[0] >= 9) {                 /* interface */
            if (found) break;
            cur_ok = (d[5] == 0x08 && d[7] == 0x50 && d[3] == 0);  /* mass storage, bulk-only */
            if (cur_ok) iface = d[2];
        } else if (d[1] == 5 && d[0] >= 7 && cur_ok) {  /* endpoint */
            if ((d[3] & 3) == 2) {
                if (d[2] & 0x80) { ep_in = d[2]; mps_in = rd16(d + 4) & 0x7FF; }
                else             { ep_out = d[2]; mps_out = rd16(d + 4) & 0x7FF; }
            }
            if (ep_in && ep_out) found = 1;
        }
    }
    if (!found) { strcpy(usb_err, "not a USB mass storage (bulk-only) device"); return -1; }
    if (hc_type == 2) {
        if (mps_in == 0) mps_in = 512;
        if (mps_out == 0) mps_out = 512;
    } else {
        if (mps_in == 0 || mps_in > 64) mps_in = 64;
        if (mps_out == 0 || mps_out > 64) mps_out = 64;
    }
    e_set_bulk();

    if (control(me, 0x00, 9, cfgval, 0, 0, NULL, NULL)) { strcpy(usb_err, "SET_CONFIGURATION failed"); return -1; }
    tog_in = tog_out = 0;
    delay_ms(10);
    control(me, 0xA1, 0xFE, 0, iface, 1, ctlbuf, &got);  /* GET MAX LUN (may stall) */

    /* INQUIRY */
    memset(cb, 0, sizeof(cb)); cb[0] = 0x12; cb[4] = 36;
    memset(ctlbuf, 0, 36);
    if (bot(cb, 6, 1, phys_of(ctlbuf), 36) < 0) { strcpy(usb_err, "INQUIRY failed"); return -1; }
    copy_trim(usb_name, ctlbuf + 8, 8);
    strcat(usb_name, " ");
    copy_trim(usb_name + strlen(usb_name), ctlbuf + 16, 16);

    /* TEST UNIT READY until the stick settles */
    for (i = 0; i < 20; i++) {
        memset(cb, 0, sizeof(cb));
        r = bot(cb, 6, 0, 0UL, 0UL);
        if (r == 0) break;
        request_sense();
        delay_ms(100);
    }

    /* READ CAPACITY(10) */
    for (i = 0; i < 5; i++) {
        memset(cb, 0, sizeof(cb)); cb[0] = 0x25;
        r = bot(cb, 10, 1, phys_of(ctlbuf), 8);
        if (r == 0) break;
        request_sense();
        delay_ms(100);
    }
    if (r) { strcpy(usb_err, "READ CAPACITY failed (no medium?)"); return -1; }
    if (be32(ctlbuf + 4) != 512) { strcpy(usb_err, "sector size isn't 512"); return -1; }
    nsect = be32(ctlbuf) + 1;
    if (verbose)
        printf("USB stick: %s, %lu MB (%s)\n", usb_name, nsect / 2048UL, usb_where);
    return 0;
}

/* ---------------- controller scans ---------------- */

static u8 pci_last;

static int scan_ehci(int flags, int verbose)
{
    u16 bus, dev, fn, vid;
    u8 devfn;
    int p, r, k, nhs, hs[16];
    u32 bar;

    for (bus = 0; bus <= pci_last; bus++)
    for (dev = 0; dev < 32; dev++)
    for (fn = 0; fn < 8; fn++) {
        devfn = (u8)((dev << 3) | fn);
        vid = pci_rw((u8)bus, devfn, 0);
        if (vid == 0xFFFF || vid == 0) { if (fn == 0) break; continue; }
        if (pci_rw((u8)bus, devfn, 0x0A) != 0x0C03) continue;
        if ((pci_rw((u8)bus, devfn, 0x08) >> 8) != 0x20) continue;   /* EHCI */
        bar = pci_rd((u8)bus, devfn, 0x10);
        if (bar & 1UL) continue;
        if ((bar & 6UL) == 4UL && pci_rd((u8)bus, devfn, 0x14)) continue;  /* above 4 GB */
        e_base = bar & ~0xFUL;
        if (!e_base) continue;
        hc_bus = (u8)bus; hc_devfn = devfn;
        if (e_take(flags)) continue;
        /* pass 1: give keyboards/mice (low/full speed) straight back to
           USB 1.1, note the USB 2.0 devices; pass 2: look for the stick */
        nhs = 0;
        for (p = 0; p < e_nports && p < 16; p++) {
            r = e_port_reset(p);
            if (r == 0) hs[nhs++] = p;
        }
        for (k = 0; k < nhs; k++) {
            p = hs[k];
            portno = p + 1;
            sprintf(usb_where, "USB 2.0, controller %02X:%02X.%X port %d", bus, dev, fn, portno);
            if (enumerate((u8)(p + 1), verbose) == 0) return 0;
            ew((u16)E_PORT(p), er((u16)E_PORT(p)) & ~0x2EUL);      /* not a stick: disable */
            if (verbose) printf("  %s: %s\n", usb_where, usb_err);
        }
        taken = 0;
        e_close();
        hc_type = 0;
    }
    return -1;
}

/* Is the BIOS polling a keyboard on this UHCI controller? (8-byte interrupt IN in its schedule) */
static int bios_kbd_here(void)
{
    u32 flb = inpd32(io + 8) & ~0xFFFUL, e, a, t, tok;
    int f, depth, guard = 0;
    if (!flb) return 0;
    for (f = 0; f < 32; f++) {
        e = mrd32(flb + (u32)f * 4);
        for (depth = 0; !(e & 1UL) && depth < 24 && guard < 3000; depth++, guard++) {
            a = e & ~0x0FUL;
            if (e & 2UL) {
                t = mrd32(a + 4);
                while (!(t & 3UL) && guard < 3000) {
                    tok = mrd32((t & ~0x0FUL) + 8);
                    if ((tok & 0xFF) == 0x69 && ((tok >> 15) & 0x0F) && (((tok >> 21) + 1) & 0x7FF) == 8)
                        return 1;
                    t = mrd32(t & ~0x0FUL);
                    guard++;
                }
                e = mrd32(a);
            } else {
                tok = mrd32(a + 8);
                if ((tok & 0xFF) == 0x69 && ((tok >> 15) & 0x0F) && (((tok >> 21) + 1) & 0x7FF) == 8)
                    return 1;
                e = mrd32(a);
            }
        }
    }
    return 0;
}

/* I/O base of the controller USBMOUSE is using (0 if it isn't loaded) */
static u16 usbmouse_io(void)
{
    union REGS r;
    if (!*(u32 far *)0x000000CCL) return 0;
    r.x.ax = 0xFF01; r.x.si = 0;
    int86(0x33, &r, &r);
    return r.x.ax == 0x5553 ? r.x.si : 0;
}

static int scan_uhci(int ctl, int verbose, int *tried)
{
    u16 bus, dev, fn, vid, p, ps[2], mio = usbmouse_io();
    u8 devfn;
    int k = 0, peek;

    a20_on();
    peek = unreal_on() == 0;
    for (bus = 0; bus <= pci_last; bus++)
    for (dev = 0; dev < 32; dev++)
    for (fn = 0; fn < 8; fn++) {
        devfn = (u8)((dev << 3) | fn);
        vid = pci_rw((u8)bus, devfn, 0);
        if (vid == 0xFFFF || vid == 0) { if (fn == 0) break; continue; }
        if (pci_rw((u8)bus, devfn, 0x0A) != 0x0C03) continue;
        if ((pci_rw((u8)bus, devfn, 0x08) >> 8) != 0x00) continue;   /* UHCI */
        k++;
        if (ctl && k != ctl) continue;
        io = pci_rw((u8)bus, devfn, 0x20) & 0xFFE0;
        if (!io) continue;
        hc_bus = (u8)bus; hc_devfn = devfn;
        ps[0] = inpw(io + 0x10); ps[1] = inpw(io + 0x12);
        if (!(ps[0] & 1) && !(ps[1] & 1)) continue;          /* nothing plugged in */
        if (io == mio) {
            if (verbose) printf("  skipping USB controller %d (USBMOUSE is using it)\n", k);
            continue;
        }
        if (!ctl && peek && bios_kbd_here()) {
            if (verbose) printf("  skipping USB controller %d (the BIOS is using a keyboard there)\n", k);
            continue;
        }
        if (!ctl && (((ps[0] & 0x101) == 0x101) || ((ps[1] & 0x101) == 0x101))) {
            if (verbose) printf("  skipping USB controller %d (keyboard/mouse on it)\n", k);
            continue;
        }
        u_take();
        (*tried)++;
        for (p = 0; p < 2; p++) {
            if (!(inpw(io + 0x10 + p * 2) & 1)) continue;
            portno = p + 1;
            sprintf(usb_where, "controller %02X:%02X.%X port %d", bus, dev, fn, portno);
            if (u_port_reset(p)) { strcpy(usb_err, "port reset failed"); continue; }
            if (lowspeed) {
                strcpy(usb_err, "low-speed device (keyboard/mouse?), not a stick");
            } else if (enumerate((u8)(p + 1), verbose) == 0) return 0;
            outpw(io + 0x10 + p * 2, 0);              /* not a stick: switch that port off */
            if (verbose) printf("  %s: %s\n", usb_where, usb_err);
        }
        taken = 0;
        u_close();
        hc_type = 0;
    }
    return -1;
}

/* ---------------- public ---------------- */

void usb_close(void)
{
    if (!taken) return;
    taken = 0;
    if (hc_type == 2) { unreal_on(); e_close(); }
    else u_close();
    hc_type = 0;
}

int usb_open(int ctl, int verbose, int flags)
{
    union REGS r;
    struct SREGS s;
    int tried = 0;
    u32 base;

    usb_err[0] = usb_name[0] = 0;
    segread(&s);
    ds_phys = (u32)s.ds << 4;
    base = phys_of(hcmem);
    mem4k = (base + 4095UL) & ~4095UL;
    mem4k_p = (vu32 *)(hcmem + (u16)(mem4k - base));
    flist = mem4k_p;
    qh = flist + 1024;
    tdp = qh + 4;
    td0_phys = vphys(tdp);

    r.x.ax = 0xB101; r.x.di = 0;
    int86(0x1A, &r, &r);
    if (r.x.cflag || r.h.ah != 0 || r.x.dx != 0x4350) { strcpy(usb_err, "no PCI BIOS"); return -1; }
    pci_last = r.h.cl;

    /* USB 2.0 first when allowed: flag 1 = only if the BIOS already routes
       the ports to it, flag 2 = switch them over (/2) */
    if (!ctl && (flags & 3)) {
        if (scan_ehci(flags, verbose) == 0) return 0;
    }
    if (scan_uhci(ctl, verbose, &tried) == 0) return 0;
    if (!tried && !usb_err[0])
        strcpy(usb_err, "no USB port has a stick plugged in");
    return -1;
}

unsigned long usb_sectors(void) { return nsect; }

int usb_rw(int wr, unsigned long lba, unsigned n, unsigned char *buf)
{
    u8 cb[10];
    u16 cnt;
    int r, tries;

    if (hc_type == 2) unreal_on();        /* DOS/XMS may have reset FS's limit */
    while (n) {
        cnt = n > 32 ? 32 : n;
        for (tries = 0; tries < 4; tries++) {
            memset(cb, 0, 10);
            cb[0] = (u8)(wr ? 0x2A : 0x28);
            cb[2] = (u8)(lba >> 24); cb[3] = (u8)(lba >> 16);
            cb[4] = (u8)(lba >> 8);  cb[5] = (u8)lba;
            cb[7] = (u8)(cnt >> 8);  cb[8] = (u8)cnt;
            r = bot(cb, 10, !wr, phys_of(buf), (u32)cnt * 512UL);
            if (r == 0) break;
            if (r == 1) request_sense();
            delay_ms(50);
        }
        if (r) return -1;
        lba += cnt; n -= cnt; buf += (u16)cnt * 512;
    }
    return 0;
}

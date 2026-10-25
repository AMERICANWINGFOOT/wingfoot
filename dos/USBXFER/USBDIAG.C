/*
 *  USBDIAG.C  -  find out why a USB stick isn't visible under DOS
 *
 *  Writes everything to the screen and to USBDIAG.TXT:
 *    1. BIOS facts (date, hard disk count, floppy count)
 *    2. USB controllers on the PCI bus (UHCI / OHCI / EHCI), their
 *       BIOS-legacy registers, and which UHCI ports have a device plugged in
 *    3. Every BIOS disk 00h-01h and 80h-87h: type, geometry, INT 13h
 *       extensions, EDD info, and what sector 0 looks like
 *
 *  Build (QuickC 2.5):  qcl /AS /Ox /W3 USBDIAG.C /link /ST:8192
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <dos.h>
#include <conio.h>

typedef unsigned char  u8;
typedef unsigned int   u16;
typedef unsigned long  u32;

static FILE *rep;
static u8 sec[512];
static u8 sec2[512];
static u8 edd[0x42];

static void P(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt); vprintf(fmt, ap); va_end(ap);
    if (rep) { va_start(ap, fmt); vfprintf(rep, fmt, ap); va_end(ap); }
}

static void R(const char *fmt, ...)          /* report file only */
{
    va_list ap;
    if (!rep) return;
    va_start(ap, fmt); vfprintf(rep, fmt, ap); va_end(ap);
}

static u16 rd16(const u8 *p) { return (u16)(p[0] | ((u16)p[1] << 8)); }
static u32 rd32(const u8 *p) { return (u32)rd16(p) | ((u32)rd16(p + 2) << 16); }

static void hexdump(const u8 *p, u16 n, u16 base)
{
    u16 i, j;
    for (i = 0; i < n; i += 16) {
        R("    %03X:", base + i);
        for (j = 0; j < 16 && i + j < n; j++) R(" %02X", p[i + j]);
        R("  ");
        for (j = 0; j < 16 && i + j < n; j++) R("%c", (p[i+j] >= 32 && p[i+j] < 127) ? p[i+j] : '.');
        R("\n");
    }
}

/* ---------------- BIOS ---------------- */

static void bios_info(void)
{
    u8 far *bda = (u8 far *)0x00400000L;
    char far *date = (char far *)0xF000FFF5L;
    u16 equip = *(u16 far *)(bda + 0x10);
    int i, nfl = (equip & 1) ? ((equip >> 6) & 3) + 1 : 0;
    char d[9];
    for (i = 0; i < 8; i++) d[i] = date[i];
    d[8] = 0;
    P("BIOS date %s,  hard disks (0040:0075) = %u,  floppy drives = %d\n",
      d, bda[0x75], nfl);
}

/* ---------------- PCI ---------------- */

static int pci_ok = 0;
static u8 pci_lastbus = 0;

static u16 pci_rw(u8 bus, u8 devfn, u16 reg)
{
    union REGS r;
    r.x.ax = 0xB109; r.h.bh = bus; r.h.bl = devfn; r.x.di = reg;
    int86(0x1A, &r, &r);
    if (r.x.cflag) return 0xFFFF;
    return r.x.cx;
}

static void pci_check(void)
{
    union REGS r;
    r.x.ax = 0xB101; r.x.di = 0;
    int86(0x1A, &r, &r);
    if (!r.x.cflag && r.h.ah == 0 && r.x.dx == 0x4350) {   /* "PC" of "PCI " */
        pci_ok = 1;
        pci_lastbus = r.h.cl;
        P("PCI BIOS %X.%02X, last bus %u\n", r.h.bh, r.h.bl, r.h.cl);
    } else P("PCI BIOS not found\n");
}

static void usb_controllers(void)
{
    u16 bus, dev, fn, vid, did, cls, w, i, found = 0;
    u8 devfn, pif;
    u8 cfg[256];
    static const char *kind[] = { "UHCI (USB 1.1)", "OHCI (USB 1.1)", "EHCI (USB 2.0)", "xHCI (USB 3)" };

    if (!pci_ok) return;
    P("\nUSB controllers:\n");
    for (bus = 0; bus <= pci_lastbus; bus++)
    for (dev = 0; dev < 32; dev++)
    for (fn = 0; fn < 8; fn++) {
        devfn = (u8)((dev << 3) | fn);
        vid = pci_rw((u8)bus, devfn, 0);
        if (vid == 0xFFFF || vid == 0) { if (fn == 0) break; else continue; }
        cls = pci_rw((u8)bus, devfn, 0x0A);
        if (cls != 0x0C03) continue;
        did = pci_rw((u8)bus, devfn, 2);
        pif = (u8)(pci_rw((u8)bus, devfn, 0x08) >> 8);
        found++;
        for (i = 0; i < 256; i += 2) { w = pci_rw((u8)bus, devfn, i); cfg[i] = (u8)w; cfg[i+1] = (u8)(w >> 8); }
        P("  %02X:%02X.%X  %04X:%04X  %s\n", bus, dev, fn, vid, did,
          pif <= 0x30 && !(pif & 0x0F) ? kind[pif >> 4] : "unknown type");
        if (pif == 0x00) {                               /* UHCI */
            u16 io = rd16(cfg + 0x20) & 0xFFE0, p, port;
            u16 leg = rd16(cfg + 0xC0);
            P("      I/O %04Xh  LEGSUP(C0h)=%04X  %s\n", io, leg,
              (leg & 0x0010) ? "BIOS keyboard/mouse trap ON" : "trap off");
            if (io) for (p = 0; p < 2; p++) {
                port = inpw(io + 0x10 + p * 2);
                P("      port %u: %04X  %s%s%s\n", p + 1, port,
                  (port & 1) ? "DEVICE PRESENT" : "empty",
                  (port & 4) ? ", enabled" : "",
                  (port & 0x100) ? ", low-speed" : ((port & 1) ? ", full-speed" : ""));
            }
        } else if (pif == 0x20) {                        /* EHCI */
            u32 mmio = rd32(cfg + 0x10) & 0xFFFFFF00UL;
            P("      MMIO %08lXh  FLADJ=%02X\n", mmio, cfg[0x61]);
            for (i = 0x40; i < 0xFC; i += 4)              /* legacy support cap */
                if (cfg[i] == 0x01 && (cfg[i+2] & 0xFE) == 0 && (cfg[i+3] & 0xFE) == 0 && (cfg[i+2] | cfg[i+3])) {
                    P("      USBLEGSUP at %02Xh: BIOS owns=%u OS owns=%u  SMI ctl=%08lX\n",
                      i, cfg[i+2] & 1, cfg[i+3] & 1, rd32(cfg + i + 4));
                }
            P("      (USB 2.0 ports: a stick plugged in here is handled by the EHCI;\n"
              "       the UHCI ports above then show 'empty' for it)\n");
        }
        R("      config space:\n");
        hexdump(cfg, 256, 0);
    }
    if (!found) P("  none found\n");
}

/* ---------------- INT 13h ---------------- */

static int read0_chs(u8 drv, u8 *buf, u8 *err)
{
    union REGS r; struct SREGS s;
    u8 far *fp = (u8 far *)buf;
    int t;
    for (t = 0; t < 2; t++) {
        segread(&s);
        r.x.ax = 0x0201; r.x.cx = 0x0001; r.h.dh = 0; r.h.dl = drv;
        r.x.bx = FP_OFF(fp); s.es = FP_SEG(fp);
        int86x(0x13, &r, &r, &s);
        if (!r.x.cflag) return 0;
        *err = r.h.ah;
        r.h.ah = 0; r.h.dl = drv; int86(0x13, &r, &r);
    }
    return -1;
}

static int read_ext(u8 drv, u32 lba, u8 *buf, u8 *err)
{
    static u8 dap[16];
    union REGS r; struct SREGS s;
    u8 far *fp = (u8 far *)buf, far *dp = (u8 far *)dap;
    memset(dap, 0, 16);
    dap[0] = 16; dap[2] = 1;
    dap[4] = (u8)FP_OFF(fp); dap[5] = (u8)(FP_OFF(fp) >> 8);
    dap[6] = (u8)FP_SEG(fp); dap[7] = (u8)(FP_SEG(fp) >> 8);
    dap[8] = (u8)lba; dap[9] = (u8)(lba >> 8); dap[10] = (u8)(lba >> 16); dap[11] = (u8)(lba >> 24);
    segread(&s);
    r.h.ah = 0x42; r.h.dl = drv; r.x.si = FP_OFF(dp); s.ds = FP_SEG(dp);
    int86x(0x13, &r, &r, &s);
    if (r.x.cflag) { *err = r.h.ah; return -1; }
    return 0;
}

static void describe_sector0(const u8 *b)
{
    int i;
    if (rd16(b + 510) != 0xAA55) { P("      sector 0: no 55AA signature (blank or not a PC disk)\n"); return; }
    if ((b[0] == 0xEB || b[0] == 0xE9) && rd16(b + 11) == 512 &&
        (!memcmp(b + 0x36, "FAT", 3) || !memcmp(b + 0x52, "FAT", 3))) {
        P("      sector 0: FAT boot sector (no partition table), %.8s\n",
          !memcmp(b + 0x52, "FAT", 3) ? (const char *)b + 0x52 : (const char *)b + 0x36);
        return;
    }
    if (!memcmp(b + 3, "EXFAT   ", 8)) { P("      sector 0: exFAT boot sector - not supported, reformat FAT32\n"); return; }
    if (!memcmp(b + 3, "NTFS    ", 8)) { P("      sector 0: NTFS boot sector - not supported, reformat FAT32\n"); return; }
    P("      sector 0: partition table\n");
    for (i = 0; i < 4; i++) {
        const u8 *e = b + 446 + i * 16;
        if (!e[4]) continue;
        P("        part %d: type %02Xh %s start %lu size %lu MB%s\n", i + 1, e[4],
          e[4] == 0x0B || e[4] == 0x0C ? "(FAT32)" :
          e[4] == 0x06 || e[4] == 0x0E || e[4] == 0x04 ? "(FAT16)" :
          e[4] == 0x07 ? "(NTFS/exFAT!)" : e[4] == 0xEE ? "(GPT)" :
          e[4] == 0x83 ? "(Linux ext!)" : "",
          rd32(e + 8), rd32(e + 12) / 2048UL, e[0] == 0x80 ? " active" : "");
    }
}

static void probe_drive(u8 drv)
{
    union REGS r; struct SREGS s;
    u8 far *ep = (u8 far *)edd;
    u8 err = 0;
    int ext = 0, have = 0, ok08;
    u8 t15, e08 = 0, bl = 0;
    u16 cyl = 0, hd = 0, spt = 0;
    u32 sz15 = 0;

    /* AH=15h disk type (some BIOSes don't answer it, so keep going) */
    r.x.cx = r.x.dx = 0; r.h.ah = 0x15; r.h.dl = drv;
    int86(0x13, &r, &r);
    t15 = (u8)(r.x.cflag ? 0xFF : r.h.ah);
    if (t15 == 3) sz15 = ((u32)r.x.cx << 16) | r.x.dx;

    r.h.ah = 0x08; r.h.dl = drv; r.x.di = 0;
    segread(&s); s.es = 0;
    int86x(0x13, &r, &r, &s);
    ok08 = !r.x.cflag && (r.h.cl & 0x3F);
    if (ok08) { cyl = ((((u16)r.h.cl & 0xC0) << 2) | r.h.ch) + 1; hd = r.h.dh + 1; spt = r.h.cl & 0x3F; bl = r.h.bl; }
    else e08 = r.h.ah;

    if ((t15 == 0 || t15 == 0xFF) && !ok08) {
        r.h.ah = 0x41; r.x.bx = 0x55AA; r.h.dl = drv;
        int86(0x13, &r, &r);
        if (r.x.cflag || r.x.bx != 0xAA55) { P("  %02Xh: not present\n", drv); return; }
    }
    P("  %02Xh: AH=15 type ", drv);
    if (t15 == 0xFF) P("(no answer)");
    else P("%u (%s)", t15, t15 == 0 ? "none" : t15 == 1 ? "floppy, no change line" :
           t15 == 2 ? "floppy/removable" : t15 == 3 ? "hard disk" : "?");
    if (t15 == 3) P(", %lu sectors", sz15);
    P("\n");
    if (ok08) P("      AH=08 geometry: %u cyl, %u heads, %u sec/track (drive type %02X)\n", cyl, hd, spt, bl);
    else P("      AH=08 failed, error %02Xh\n", e08);

    r.h.ah = 0x41; r.x.bx = 0x55AA; r.h.dl = drv;
    int86(0x13, &r, &r);
    if (!r.x.cflag && r.x.bx == 0xAA55) {
        ext = (r.x.cx & 1);
        P("      INT13 extensions: version %02Xh, flags %04X%s\n", r.h.ah, r.x.cx,
          ext ? "" : " (no LBA read!)");
    } else P("      INT13 extensions: none (CHS only, 8 GB limit)\n");

    if (ext) {
        memset(edd, 0, sizeof(edd));
        edd[0] = 0x42;
        segread(&s);
        r.h.ah = 0x48; r.h.dl = drv; r.x.si = FP_OFF(ep); s.ds = FP_SEG(ep);
        int86x(0x13, &r, &r, &s);
        if (!r.x.cflag) {
            P("      AH=48: %lu sectors, %u bytes/sector", rd32(edd + 0x10), rd16(edd + 0x18));
            if (rd16(edd + 0x1E) == 0xBEDD) P(", bus \"%.4s\" interface \"%.8s\"", edd + 0x24, edd + 0x28);
            P("\n");
            R("      AH=48 table:\n"); hexdump(edd, rd16(edd) > 0x42 ? 0x42 : rd16(edd), 0);
        } else P("      AH=48 failed, error %02Xh\n", r.h.ah);
    }

    if (drv < 0x80 && !ext && (!ok08 || (u32)cyl * hd * spt <= 5760UL)) {
        P("      (skipping read test on plain floppy drive)\n");
        return;
    }
    if (read0_chs(drv, sec, &err) == 0) { P("      CHS read of sector 0: OK\n"); have = 1; }
    else P("      CHS read of sector 0: FAILED, error %02Xh\n", err);
    if (ext) {
        if (read_ext(drv, 0, sec2, &err) == 0) {
            P("      LBA read of sector 0: OK%s\n", have && memcmp(sec, sec2, 512) ? " (DIFFERENT from CHS read!)" : "");
            if (!have) memcpy(sec, sec2, 512);
            have = 1;
        } else P("      LBA read of sector 0: FAILED, error %02Xh\n", err);
    }
    if (have) {
        describe_sector0(sec);
        R("      sector 0:\n"); hexdump(sec, 512, 0);
    }
}

/* ---------------- main ---------------- */

int main(void)
{
    int d, n;
    rep = fopen("USBDIAG.TXT", "w");
    P("USBDIAG 1.1 - USB stick diagnostics%s\n\n", rep ? "  (saving to USBDIAG.TXT)" : "");
    bios_info();
    pci_check();
    usb_controllers();

    P("\nBIOS disks:\n");
    for (d = 0x00; d <= 0x01; d++) probe_drive((u8)d);
    n = *(u8 far *)0x00400075L;
    if (n < 2) n = 2;
    for (d = 0x80; d < 0x80 + n + 1 && d < 0x88; d++) probe_drive((u8)d);

    P("\nWhat to look for:\n"
      "  - A drive at 81h (or 00h/01h) with the stick's size = BIOS sees it.\n"
      "  - No such drive = BIOS USB storage support is off, or the stick\n"
      "    wasn't plugged in at power-on.\n"
      "  - Partition type 07h = exFAT/NTFS; reformat the stick as FAT32.\n");
    if (rep) fclose(rep);
    return 0;
}

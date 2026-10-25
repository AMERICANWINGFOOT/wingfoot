/*
 *  USBXFER.C  -  copy files between a USB stick and DOS (MS-DOS 6.22)
 *
 *  How it works:
 *    - The BIOS "USB legacy / USB mass storage" emulation makes the stick
 *      look like a hard disk (usually BIOS drive 81h).  We read and write
 *      its sectors with INT 13h (extended calls 42h/43h, or CHS 02h/03h).
 *    - DOS 6.22 can't read FAT32, so this program has its own FAT16/FAT32
 *      code: directories, long file names (read), cluster chains, FSInfo.
 *
 *  Commands:
 *    USBXFER DRIVES                 list BIOS hard disks
 *    USBXFER INFO                   show the stick's volume
 *    USBXFER DIR  [\path\pattern]   list files on the stick
 *    USBXFER GET  \path\pattern [dest]   copy stick -> DOS
 *    USBXFER PUT  dospattern [\stickdir] copy DOS  -> stick
 *    USBXFER DEL  \path\pattern     delete files on the stick
 *    USBXFER MD   \path\newdir      make a folder on the stick
 *  Options:  /D:81  BIOS drive (hex)   /P:n  partition number   /Y  no prompts
 *
 *  Build (QuickC 2.5):   qcl /AS /Ox /W3 USBXFER.C /link /ST:8192
 *  Build (Open Watcom):  wcl -bt=dos -ms -ox -k8192 USBXFER.C
 *  USBXGUI.C #includes this file (with USBXGUI defined) for the mouse GUI.
 *  Host test (Linux):    gcc -DHOSTTEST -o usbxfer USBXFER.C
 *                        ./usbxfer /I:disk.img DIR
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <time.h>

#ifdef HOSTTEST
#include <stdint.h>
typedef uint8_t  u8;
typedef uint16_t u16;
typedef uint32_t u32;
#else
#include <dos.h>
#include <conio.h>
#include <io.h>
#include <signal.h>
#include "USBDRV.H"
typedef unsigned char  u8;
typedef unsigned int   u16;
typedef unsigned long  u32;
#endif

#define VERSION   "2.2"
#define SECSZ     512
#define BUFSECS   32                    /* 16 KB transfer buffer */
#define NOCACHE   0xFFFFFFFFUL
#define UL(x)     ((unsigned long)(x))

/* ------------------------------------------------------------------ */
/*  Globals                                                           */
/* ------------------------------------------------------------------ */

static u8  databuf[BUFSECS * SECSZ];
static u8  secbuf[SECSZ];
static u8  fatbuf[SECSZ];
static u8  dirbuf[SECSZ];

static u32 fat_lba = NOCACHE;  static int fat_dirty = 0;
static u32 dir_lba = NOCACHE;  static int dir_dirty = 0;

static int g_drive = -1;        /* BIOS drive number               */
static int g_part  = 0;         /* 0 = first FAT partition         */
static int g_yes   = 0;         /* /Y : answer yes to everything   */
static int g_usb   = 0;         /* 1 = talking to the USB controller directly */
static int g_force_usb = 0;     /* /U   */
static int g_ctl   = 0;         /* /C:n */
static int g_usbfl = 1;         /* 1 = USB 2.0 only if already routed, 3 = /2 */
#ifdef HOSTTEST
static FILE *g_img = NULL;
static char *g_imgname = NULL;
#endif

/* disk */
static int d_ext;               /* INT 13h extensions available    */
static u32 d_total;             /* total sectors                   */
static u16 d_heads, d_spt, d_cyls;
static char d_iface[9];

/* volume */
static int v_type;              /* 16 or 32                        */
static u32 v_start;             /* partition start LBA             */
static u8  v_spc, v_nfats;
static u16 v_rootents;
static u32 v_fat, v_fatsz, v_root, v_rootsecs, v_data;
static u32 v_clusters, v_maxclus, v_rootclus, v_clusbytes;
static u32 v_fsinfo, v_free, v_hint;
static long v_freedelta;
static u32 v_serial;
static char v_label[12];

/* ------------------------------------------------------------------ */
/*  Little helpers                                                    */
/* ------------------------------------------------------------------ */

static u16 rd16(const u8 *p) { return (u16)(p[0] | ((u16)p[1] << 8)); }
static u32 rd32(const u8 *p) { return (u32)rd16(p) | ((u32)rd16(p + 2) << 16); }
static void wr16(u8 *p, u16 v) { p[0] = (u8)v; p[1] = (u8)(v >> 8); }
static void wr32(u8 *p, u32 v) { wr16(p, (u16)(v & 0xFFFF)); wr16(p + 2, (u16)(v >> 16)); }

static void die(const char *msg)
{
#ifdef USBXGUI
    gui_die(msg);                       /* longjmps back to the GUI */
#endif
    printf("\nUSBXFER: %s\n", msg);
    exit(2);
}

static int ci_eq(const char *a, const char *b)
{
    while (*a && *b) {
        if (toupper((u8)*a) != toupper((u8)*b)) return 0;
        a++; b++;
    }
    return *a == *b;
}

/* DOS-style wildcard match, case-insensitive */
static int glob(const char *p, const char *s)
{
    while (*p) {
        if (*p == '*') {
            p++;
            if (!*p) return 1;
            while (*s) { if (glob(p, s)) return 1; s++; }
            return 0;
        }
        if (!*s) return 0;
        if (*p != '?' && toupper((u8)*p) != toupper((u8)*s)) return 0;
        p++; s++;
    }
    return *s == 0;
}

static int has_wild(const char *s) { return strchr(s, '*') || strchr(s, '?'); }

static int ask(const char *q)
{
    int c;
    if (g_yes) return 1;
#ifdef USBXGUI
    c = gui_ask(q);
    if (c == 'A') { g_yes = 1; return 1; }
    return c == 'Y';
#endif
    printf("%s (Yes/No/All)? ", q);
#ifdef HOSTTEST
    c = getchar();
    { int d; while ((d = getchar()) != '\n' && d != EOF) ; }
#else
    c = getch();
    printf("%c\n", isprint(c) ? c : ' ');
#endif
    c = toupper(c);
    if (c == 'A') { g_yes = 1; return 1; }
    return c == 'Y';
}

/* ------------------------------------------------------------------ */
/*  Sector I/O                                                        */
/* ------------------------------------------------------------------ */

#ifdef HOSTTEST

static int disk_open(int drv)
{
    long sz;
    (void)drv;
    if (!g_imgname) return -1;
    if (!g_img) g_img = fopen(g_imgname, "r+b");
    if (!g_img) return -1;
    fseek(g_img, 0, SEEK_END);
    sz = ftell(g_img);
    d_total = (u32)(sz / SECSZ);
    d_ext = 1; d_heads = 255; d_spt = 63; d_cyls = 0;
    strcpy(d_iface, "IMAGE");
    return 0;
}

static int raw_rw(int wr, u32 lba, u16 n, u8 *buf)
{
    if (fseek(g_img, (long)lba * SECSZ, SEEK_SET)) return -1;
    if (wr) { if (fwrite(buf, SECSZ, n, g_img) != n) return -1; fflush(g_img); }
    else    { if (fread(buf, SECSZ, n, g_img) != n) return -1; }
    return 0;
}

#else /* real DOS */

static int bios_ext_rw(int wr, u32 lba, u16 n, u8 *buf)
{
    static u8 dap[16];
    union REGS r;
    struct SREGS s;
    u8 far *fp = (u8 far *)buf;
    u8 far *dp = (u8 far *)dap;
    int tries;

    for (tries = 0; tries < 3; tries++) {
        dap[0] = 16; dap[1] = 0;
        wr16(dap + 2, n);
        wr16(dap + 4, FP_OFF(fp));
        wr16(dap + 6, FP_SEG(fp));
        wr32(dap + 8, lba);
        wr32(dap + 12, 0);
        segread(&s);
        r.h.ah = (u8)(wr ? 0x43 : 0x42);
        r.h.al = 0;
        r.h.dl = (u8)g_drive;
        r.x.si = FP_OFF(dp);
        s.ds   = FP_SEG(dp);
        int86x(0x13, &r, &r, &s);
        if (!r.x.cflag) return 0;
        r.h.ah = 0; r.h.dl = (u8)g_drive;        /* reset and retry */
        int86(0x13, &r, &r);
    }
    return -1;
}

static int bios_chs_rw(int wr, u32 lba, u16 n, u8 *buf)
{
    union REGS r;
    struct SREGS s;
    u8 far *fp;
    u16 sec, head, cyl, cnt;
    u32 t;
    int tries, ok;

    while (n) {
        sec  = (u16)(lba % d_spt) + 1;
        t    = lba / d_spt;
        head = (u16)(t % d_heads);
        cyl  = (u16)(t / d_heads);
        if (t / d_heads > 1023) return -1;
        cnt = d_spt - sec + 1;                /* stay inside one track */
        if (cnt > n) cnt = n;
        fp = (u8 far *)buf;
        ok = 0;
        for (tries = 0; tries < 3 && !ok; tries++) {
            segread(&s);
            r.h.ah = (u8)(wr ? 0x03 : 0x02);
            r.h.al = (u8)cnt;
            r.h.ch = (u8)(cyl & 0xFF);
            r.h.cl = (u8)((sec & 0x3F) | ((cyl >> 2) & 0xC0));
            r.h.dh = (u8)head;
            r.h.dl = (u8)g_drive;
            r.x.bx = FP_OFF(fp);
            s.es   = FP_SEG(fp);
            int86x(0x13, &r, &r, &s);
            if (!r.x.cflag) ok = 1;
            else { r.h.ah = 0; r.h.dl = (u8)g_drive; int86(0x13, &r, &r); }
        }
        if (!ok) return -1;
        buf += (u16)cnt * SECSZ;
        lba += cnt;
        n   -= cnt;
    }
    return 0;
}

static int raw_rw(int wr, u32 lba, u16 n, u8 *buf)
{
    if (g_usb) return usb_rw(wr, lba, n, buf);
    return d_ext ? bios_ext_rw(wr, lba, n, buf) : bios_chs_rw(wr, lba, n, buf);
}

/* Probe a BIOS drive. Returns 0 if it answers. */
static int disk_open(int drv)
{
    union REGS r;
    struct SREGS s;
    u8 far *bp = (u8 far *)secbuf;
    int geo = 0;

    g_drive = drv;
    d_ext = 0; d_total = 0; d_iface[0] = 0;
    d_heads = d_spt = d_cyls = 0;

    /* geometry (needed for CHS fallback) */
    r.h.ah = 0x08; r.h.dl = (u8)drv; r.x.di = 0;
    segread(&s); s.es = 0;
    int86x(0x13, &r, &r, &s);
    if (!r.x.cflag && (r.h.cl & 0x3F)) {
        d_heads = (u16)r.h.dh + 1;
        d_spt   = r.h.cl & 0x3F;
        d_cyls  = (u16)((((u16)r.h.cl & 0xC0) << 2) | r.h.ch) + 1;
        d_total = (u32)d_cyls * d_heads * d_spt;
        geo = 1;
    }

    /* extensions present? */
    r.h.ah = 0x41; r.x.bx = 0x55AA; r.h.dl = (u8)drv;
    int86(0x13, &r, &r);
    if (!r.x.cflag && r.x.bx == 0xAA55 && (r.x.cx & 1)) {
        d_ext = 1;
        memset(secbuf, 0, 0x42);
        wr16(secbuf, 0x42);
        segread(&s);
        r.h.ah = 0x48; r.h.dl = (u8)drv;
        r.x.si = FP_OFF(bp); s.ds = FP_SEG(bp);
        int86x(0x13, &r, &r, &s);
        if (!r.x.cflag) {
            u32 lo = rd32(secbuf + 0x10), hi = rd32(secbuf + 0x14);
            u16 bps = rd16(secbuf + 0x18);
            if (bps != 0 && bps != SECSZ) return -1;   /* not 512-byte sectors */
            if (hi) lo = 0xFFFFFFFFUL;
            if (lo) d_total = lo;
            if (rd16(secbuf + 0x1E) == 0xBEDD) {     /* EDD 3.0 device path */
                memcpy(d_iface, secbuf + 0x28, 8);
                d_iface[8] = 0;
                { int i = 7; while (i >= 0 && d_iface[i] == ' ') d_iface[i--] = 0; }
            }
        }
    }
    if (!d_ext && !geo) return -1;
    return 0;
}

#endif /* HOSTTEST */

static void disk_read(u32 lba, u16 n, u8 *buf)
{
    if (raw_rw(0, lba, n, buf)) {
        char m[60];
        sprintf(m, "read error at sector %lu", UL(lba));
        die(m);
    }
}

static void disk_write(u32 lba, u16 n, u8 *buf)
{
    if (raw_rw(1, lba, n, buf)) {
        char m[60];
        sprintf(m, "WRITE error at sector %lu", UL(lba));
        die(m);
    }
}

/* ------------------------------------------------------------------ */
/*  Volume (partition + BPB)                                          */
/* ------------------------------------------------------------------ */

static int is_fat_vbr(const u8 *b)
{
    u8 spc = b[13];
    if (rd16(b + 510) != 0xAA55) return 0;
    if (b[0] != 0xEB && b[0] != 0xE9) return 0;
    if (rd16(b + 11) != SECSZ) return 0;
    if (spc == 0 || (spc & (spc - 1))) return 0;
    if (rd16(b + 14) == 0 || b[16] == 0) return 0;
    return 1;
}


static void copy_label(char *dst, const u8 *src)
{
    int i;
    memcpy(dst, src, 11); dst[11] = 0;
    for (i = 10; i >= 0 && dst[i] == ' '; i--) dst[i] = 0;
}

/* Returns 0 ok, else error text in msg */
static int vol_mount(char *msg)
{
    u8 *b = secbuf;
    u32 totsec, fatsz, sysecs;
    u16 resv;
    int i, n;

    if (raw_rw(0, 0, 1, b)) { strcpy(msg, "can't read sector 0"); return -1; }
    v_start = 0;
    if (!(is_fat_vbr(b) && (memcmp(b + 0x36, "FAT", 3) == 0 ||
                            memcmp(b + 0x52, "FAT", 3) == 0))) {
        u32 cand[16];
        int nc = 0, gpt = 0;
        if (rd16(b + 510) != 0xAA55) { strcpy(msg, "no partition table"); return -1; }
        for (i = 0; i < 4; i++) {
            u8 *e = b + 446 + i * 16;
            if (e[4] == 0xEE) gpt = 1;
            else if (e[4] && e[4] != 0x05 && e[4] != 0x0F && e[4] != 0x85 && rd32(e + 8))
                cand[nc++] = rd32(e + 8);
        }
        if (gpt) {                       /* GUID partition table */
            u32 elba, cnt, esz, k, lastlba = 0xFFFFFFFFUL;
            nc = 0;
            if (raw_rw(0, 1, 1, b) || memcmp(b, "EFI PART", 8)) { strcpy(msg, "bad GPT header"); return -1; }
            elba = rd32(b + 72); cnt = rd32(b + 80); esz = rd32(b + 84);
            if (esz < 128 || esz > SECSZ || (SECSZ % esz)) { strcpy(msg, "odd GPT entry size"); return -1; }
            if (cnt > 128) cnt = 128;
            for (k = 0; k < cnt && nc < 16; k++) {
                u32 lba = elba + k * esz / SECSZ;
                u8 *e;
                if (lba != lastlba) {
                    if (raw_rw(0, lba, 1, databuf)) { strcpy(msg, "can't read GPT entries"); return -1; }
                    lastlba = lba;
                }
                e = databuf + (u16)((k * esz) % SECSZ);
                if (rd32(e) | rd32(e + 4) | rd32(e + 8) | rd32(e + 12))
                    if (rd32(e + 32) && !rd32(e + 36)) cand[nc++] = rd32(e + 32);
            }
        }
        n = 0;
        for (i = 0; i < nc; i++) {
            if (raw_rw(0, cand[i], 1, b)) continue;
            if (!is_fat_vbr(b)) continue;
            n++;
            if ((g_part == 0 && n == 1) || g_part == n) { v_start = cand[i]; break; }
        }
        if (i == nc) {
            strcpy(msg, gpt ? "no FAT partition in GPT" : "no FAT16/FAT32 partition found");
            return -1;
        }
    }

    v_spc     = b[13];
    resv      = rd16(b + 14);
    v_nfats   = b[16];
    v_rootents= rd16(b + 17);
    totsec    = rd16(b + 19) ? (u32)rd16(b + 19) : rd32(b + 32);
    fatsz     = rd16(b + 22) ? (u32)rd16(b + 22) : rd32(b + 36);
    v_fatsz   = fatsz;
    v_fat     = v_start + resv;
    v_rootsecs= ((u32)v_rootents * 32 + SECSZ - 1) / SECSZ;
    v_root    = v_fat + (u32)v_nfats * fatsz;
    v_data    = v_root + v_rootsecs;
    sysecs    = resv + (u32)v_nfats * fatsz + v_rootsecs;
    if (totsec <= sysecs) { strcpy(msg, "bad boot sector"); return -1; }
    v_clusters= (totsec - sysecs) / v_spc;
    v_maxclus = v_clusters + 1;
    v_clusbytes = (u32)v_spc * SECSZ;
    v_free = 0xFFFFFFFFUL; v_hint = 2; v_freedelta = 0; v_fsinfo = 0;

    if (v_clusters < 4085) { strcpy(msg, "FAT12 volume (not supported)"); return -1; }
    if (v_clusters < 65525) {
        v_type = 16;
        v_rootclus = 0;
        v_serial = rd32(b + 0x27);
        copy_label(v_label, b + 0x2B);
        {   /* FAT16 has no FSInfo: count free clusters (max 256 sectors) */
            u32 c = 0, lba = v_fat, left = fatsz;
            u16 n, k;
            v_free = 0;
            while (left) {
                n = (left > BUFSECS) ? (u16)BUFSECS : (u16)left;
                disk_read(lba, n, databuf);
                for (k = 0; k < n * (SECSZ / 2); k++, c++)
                    if (c >= 2 && c <= v_maxclus && rd16(databuf + k * 2) == 0) v_free++;
                lba += n; left -= n;
            }
        }
    } else {
        v_type = 32;
        v_rootclus = rd32(b + 44);
        v_serial = rd32(b + 0x43);
        copy_label(v_label, b + 0x47);
        if (rd16(b + 48) && rd16(b + 48) != 0xFFFF) {
            v_fsinfo = v_start + rd16(b + 48);
            disk_read(v_fsinfo, 1, b);
            if (rd32(b) == 0x41615252UL && rd32(b + 484) == 0x61417272UL) {
                v_free = rd32(b + 488);
                if (v_free > v_clusters) v_free = 0xFFFFFFFFUL;
                v_hint = rd32(b + 492);
            } else v_fsinfo = 0;
        }
    }
    if (v_hint < 2 || v_hint > v_maxclus) v_hint = 2;
    return 0;
}

static u32 clus2lba(u32 c) { return v_data + (c - 2) * v_spc; }

/* ------------------------------------------------------------------ */
/*  FAT access (one-sector write-back cache, mirrored to all FATs)    */
/* ------------------------------------------------------------------ */

static void fat_flush(void)
{
    u8 i;
    if (fat_dirty) {
        for (i = 0; i < v_nfats; i++) disk_write(fat_lba + (u32)i * v_fatsz, 1, fatbuf);
        fat_dirty = 0;
    }
}

static u16 fat_locate(u32 c)
{
    u32 off = c * (v_type == 32 ? 4 : 2);
    u32 lba = v_fat + off / SECSZ;
    if (lba != fat_lba) {
        fat_flush();
        disk_read(lba, 1, fatbuf);
        fat_lba = lba;
    }
    return (u16)(off % SECSZ);
}

static u32 fat_get(u32 c)
{
    u16 o = fat_locate(c);
    return v_type == 32 ? (rd32(fatbuf + o) & 0x0FFFFFFFUL) : rd16(fatbuf + o);
}

static void fat_set(u32 c, u32 v)
{
    u16 o = fat_locate(c);
    if (v_type == 32) wr32(fatbuf + o, (rd32(fatbuf + o) & 0xF0000000UL) | (v & 0x0FFFFFFFUL));
    else              wr16(fatbuf + o, (u16)v);
    fat_dirty = 1;
}

static int  fat_eoc(u32 c)  { return v_type == 32 ? c >= 0x0FFFFFF8UL : c >= 0xFFF8UL; }
static u32  fat_eocval(void){ return v_type == 32 ? 0x0FFFFFFFUL : 0xFFFFUL; }
static int  clus_ok(u32 c)  { return c >= 2 && c <= v_maxclus; }

static void fat_free_chain(u32 c)
{
    u32 n, guard = 0;
    while (clus_ok(c) && guard++ <= v_clusters) {
        n = fat_get(c);
        fat_set(c, 0);
        v_freedelta++;
        if (fat_eoc(n) || n == 0) break;
        c = n;
    }
}

static u32 fat_find_free(void)
{
    u32 c = v_hint, i;
    if (!clus_ok(c)) c = 2;
    for (i = 0; i < v_clusters; i++) {
        if (fat_get(c) == 0) return c;
        if (++c > v_maxclus) c = 2;
    }
    return 0;
}

static void fsinfo_update(void)
{
    fat_flush();
    if (v_type != 32 || !v_fsinfo) return;
    disk_read(v_fsinfo, 1, secbuf);
    if (rd32(secbuf) != 0x41615252UL) return;
    if (v_free != 0xFFFFFFFFUL) {
        v_free = (u32)((long)v_free + v_freedelta);
        wr32(secbuf + 488, v_free);
    }
    wr32(secbuf + 492, v_hint);
    disk_write(v_fsinfo, 1, secbuf);
    v_freedelta = 0;
}

/* ------------------------------------------------------------------ */
/*  Directory access                                                  */
/* ------------------------------------------------------------------ */

typedef struct {
    u32 clus;       /* current cluster (0 for FAT16 fixed root) */
    u32 lba;        /* current sector                            */
    u16 secin;      /* sector index within cluster / root area   */
    u16 ent;        /* entry 0..15 within sector                 */
    u32 idx;        /* running entry number                      */
    int fixed;      /* FAT16 root directory                      */
    int done;
} DIT;

typedef struct {
    char sname[13];         /* 8.3 name, upper case, "NAME.EXT"   */
    char lname[256];        /* long name (or case-adjusted 8.3)   */
    int  haslong;           /* lname differs from sname            */
    u8   attr;
    u32  clus, size;
    u16  date, time;
    u32  lba;               /* where the short entry lives         */
    u16  off;
    u32  idx;
    DIT  start;             /* iterator state at first LFN entry   */
} DENT;

static void dir_flush(void)
{
    if (dir_dirty) { disk_write(dir_lba, 1, dirbuf); dir_dirty = 0; }
}

static u8 *dir_load(u32 lba)
{
    if (lba != dir_lba) {
        dir_flush();
        disk_read(lba, 1, dirbuf);
        dir_lba = lba;
    }
    return dirbuf;
}

static void dit_open(DIT *it, u32 dclus)
{
    memset(it, 0, sizeof(*it));
    if (dclus == 0 && v_type == 16) {
        it->fixed = 1;
        it->lba = v_root;
    } else {
        it->clus = dclus ? dclus : v_rootclus;
        it->lba = clus2lba(it->clus);
    }
}

static u8 *dit_get(DIT *it)
{
    return dir_load(it->lba) + it->ent * 32;
}

static int dit_next(DIT *it)
{
    u32 n;
    if (++it->ent < 16) { it->idx++; return 1; }
    if (it->fixed) {
        if ((u32)it->secin + 1 >= v_rootsecs) { it->ent = 15; return 0; }
        it->secin++; it->lba++;
    } else if (it->secin + 1 < v_spc) {
        it->secin++; it->lba++;
    } else {
        n = fat_get(it->clus);
        if (!clus_ok(n)) { it->ent = 15; return 0; }
        it->clus = n; it->secin = 0; it->lba = clus2lba(n);
    }
    it->ent = 0;
    it->idx++;
    return 1;
}

static u8 lfn_sum(const u8 *e)
{
    u8 s = 0; int i;
    for (i = 0; i < 11; i++) s = (u8)(((s & 1) << 7) + (s >> 1) + e[i]);
    return s;
}

static void short_name(const u8 *e, char *out, char *disp)
{
    int i, n = 0;
    u8 c;
    for (i = 0; i < 8 && e[i] != ' '; i++) {
        c = e[i]; if (i == 0 && c == 0x05) c = 0xE5;
        out[n] = (char)c;
        disp[n] = (char)((e[12] & 0x08) ? tolower(c) : c);
        n++;
    }
    if (e[8] != ' ') {
        out[n] = disp[n] = '.'; n++;
        for (i = 8; i < 11 && e[i] != ' '; i++) {
            out[n] = (char)e[i];
            disp[n] = (char)((e[12] & 0x10) ? tolower(e[i]) : e[i]);
            n++;
        }
    }
    out[n] = disp[n] = 0;
}

/* Read the next real entry (skips deleted, volume label, LFN parts) */
static int dir_read(DIT *it, DENT *d)
{
    static const u8 lfo[13] = {1,3,5,7,9,14,16,18,20,22,24,28,30};
    u8 *e, chk = 0, seq;
    int have = 0, k, pos;
    DIT st;

    while (!it->done) {
        e = dit_get(it);
        if (e[0] == 0) { it->done = 1; return 0; }
        if (e[0] == 0xE5) {
            have = 0;
        } else if ((e[11] & 0x3F) == 0x0F) {
            seq = e[0];
            if (seq & 0x40) {
                memset(d->lname, 0, sizeof(d->lname));
                have = 1; chk = e[13]; st = *it;
            } else if (!have || e[13] != chk) {
                have = 0;
            }
            if (have) {
                pos = ((seq & 0x1F) - 1) * 13;
                for (k = 0; k < 13 && pos + k < 255; k++) {
                    u16 ch = rd16(e + lfo[k]);
                    if (ch == 0 || ch == 0xFFFF) break;
                    d->lname[pos + k] = (char)(ch < 256 ? ch : '?');
                }
            }
        } else if (!(e[11] & 0x08)) {          /* skip volume label */
            char disp[13];
            short_name(e, d->sname, disp);
            if (have && lfn_sum(e) == chk && d->lname[0]) {
                d->start = st;
            } else {
                strcpy(d->lname, disp);
                d->start = *it;
            }
            d->haslong = strcmp(d->lname, d->sname) != 0;
            d->attr = e[11];
            d->clus = ((u32)rd16(e + 20) << 16) | rd16(e + 26);
            if (v_type == 16) d->clus &= 0xFFFF;
            d->size = rd32(e + 28);
            d->time = rd16(e + 22);
            d->date = rd16(e + 24);
            d->lba  = it->lba;
            d->off  = it->ent * 32;
            d->idx  = it->idx;
            if (!dit_next(it)) it->done = 1;
            return 1;
        } else {
            have = 0;
        }
        if (!dit_next(it)) it->done = 1;
    }
    return 0;
}

static int dent_match(const DENT *d, const char *pat)
{
    return glob(pat, d->sname) || glob(pat, d->lname);
}

static int dir_find(u32 dclus, const char *name, DENT *out)
{
    DIT it;
    dit_open(&it, dclus);
    while (dir_read(&it, out))
        if (ci_eq(name, out->sname) || ci_eq(name, out->lname)) return 1;
    return 0;
}

/* Walk "\a\b\c" (or /a/b/c). Every part must be a folder. */
static int resolve_dir(const char *path, u32 *dclus)
{
    static DENT d;
    char part[256];
    u32 c = 0;
    int n;

    while (*path) {
        while (*path == '\\' || *path == '/') path++;
        if (!*path) break;
        n = 0;
        while (*path && *path != '\\' && *path != '/' && n < 255) part[n++] = *path++;
        part[n] = 0;
        if (strcmp(part, ".") == 0) continue;
        if (!dir_find(c, part, &d) || !(d.attr & 0x10)) return 0;
        c = d.clus;        /* ".." to root gives 0, which means root */
        if (v_type == 32 && c == v_rootclus) c = 0;
    }
    *dclus = c;
    return 1;
}

/* Split "\dir\sub\pat" into folder cluster + pattern.
   If the whole path is a folder, the pattern becomes "*". */
static int resolve_pattern(const char *path, u32 *dclus, char *pat)
{
    char dirp[256];
    const char *p1, *p2, *slash;
    u32 c;

    if (resolve_dir(path, &c) && !has_wild(path)) {
        *dclus = c; strcpy(pat, "*");
        return 1;
    }
    p1 = strrchr(path, '\\'); p2 = strrchr(path, '/');
    slash = p1 > p2 ? p1 : p2;
    if (slash) {
        size_t n = (size_t)(slash - path);
        if (n > 255) n = 255;
        memcpy(dirp, path, n); dirp[n] = 0;
        strcpy(pat, slash + 1);
    } else {
        dirp[0] = 0;
        strcpy(pat, path);
    }
    if (strcmp(pat, "*.*") == 0) strcpy(pat, "*");
    if (!pat[0]) strcpy(pat, "*");
    if (!resolve_dir(dirp, dclus)) return 0;
    return 1;
}

static void fill_entry(u8 *e, const u8 *n83, u8 attr, u32 clus, u32 size, u16 date, u16 tim)
{
    memset(e, 0, 32);
    memcpy(e, n83, 11);
    e[11] = attr;
    wr16(e + 14, tim);  wr16(e + 16, date);   /* created  */
    wr16(e + 18, date);                       /* accessed */
    wr16(e + 20, (u16)(clus >> 16));
    wr16(e + 22, tim);  wr16(e + 24, date);   /* modified */
    wr16(e + 26, (u16)(clus & 0xFFFF));
    wr32(e + 28, size);
}

/* Make an 11-byte FAT name from "NAME.EXT". 0 if not a valid 8.3 name. */
static int make_83(const char *name, u8 *out)
{
    static const char bad[] = "\"*+,/:;<=>?[\\]|";
    int i = 0, n;
    const char *p = name;
    memset(out, ' ', 11);
    if (!*p || strcmp(p, ".") == 0 || strcmp(p, "..") == 0) return 0;
    for (n = 0; *p && *p != '.'; p++, n++) {
        if (n >= 8 || (u8)*p <= ' ' || strchr(bad, *p)) return 0;
        out[i++] = (u8)toupper((u8)*p);
    }
    if (n == 0) return 0;
    if (*p == '.') {
        p++; i = 8;
        for (n = 0; *p; p++, n++) {
            if (n >= 3 || *p == '.' || (u8)*p <= ' ' || strchr(bad, *p)) return 0;
            out[i++] = (u8)toupper((u8)*p);
        }
    }
    if (out[0] == 0xE5) out[0] = 0x05;
    return 1;
}

static void zero_cluster(u32 c)
{
    u32 lba = clus2lba(c);
    u16 left = v_spc, n;
    dir_flush();
    memset(databuf, 0, sizeof(databuf));
    while (left) {
        n = left > BUFSECS ? BUFSECS : left;
        disk_write(lba, n, databuf);
        lba += n; left -= n;
    }
    dir_lba = NOCACHE;
}

/* Find (or make) a free 32-byte slot in a folder. */
static int dir_free_slot(u32 dclus, u32 *lba, u16 *off)
{
    DIT it;
    u8 *e;
    u32 last, nc;

    dit_open(&it, dclus);
    for (;;) {
        e = dit_get(&it);
        if (e[0] == 0 || e[0] == 0xE5) { *lba = it.lba; *off = it.ent * 32; return 1; }
        last = it.clus;
        if (!dit_next(&it)) break;
    }
    if (it.fixed) return 0;                 /* FAT16 root is full */
    nc = fat_find_free();
    if (!nc) return 0;
    fat_set(nc, fat_eocval());
    fat_set(last, nc);
    v_freedelta--; v_hint = nc + 1;
    fat_flush();
    zero_cluster(nc);
    *lba = clus2lba(nc); *off = 0;
    return 1;
}

/* Delete the short entry and its long-name entries */
static void dir_erase(DENT *d)
{
    DIT it = d->start;
    u8 *e;
    for (;;) {
        e = dit_get(&it);
        e[0] = 0xE5;
        dir_dirty = 1;
        if (it.idx >= d->idx) break;
        if (!dit_next(&it)) break;
    }
    dir_flush();
}

/* ------------------------------------------------------------------ */
/*  Data transfer                                                     */
/* ------------------------------------------------------------------ */

static unsigned long t_bytes;

static void progress(const char *name, u32 done, u32 total)
{
    static clock_t last = 0;
    clock_t now;
#ifdef USBXGUI
    gui_progress(name, done, total);
    return;
#endif
    if (total < 65536UL) return;
    now = clock();
    if (done < total && now - last < CLOCKS_PER_SEC / 5 && now >= last) return;
    last = now;
    printf("\r  %-12s %8luK of %luK", name, UL(done >> 10), UL(total >> 10));
}

/* stick -> file */
static int chain_to_file(u32 c, u32 size, FILE *fp, const char *name)
{
    u32 left = size, n, nx, lba, secs, want, run, maxrun;
    u16 chunk, rs;

    maxrun = v_spc <= BUFSECS ? BUFSECS / v_spc : 1;
    while (left) {
        if (!clus_ok(c)) { printf("\n  bad cluster chain\n"); return -1; }
        run = 1; n = c;
        while (run < maxrun && run * v_clusbytes < left) {
            nx = fat_get(n);
            if (nx != n + 1) break;
            n = nx; run++;
        }
        lba = clus2lba(c);
        secs = run * v_spc;
        while (secs && left) {
            chunk = (secs > BUFSECS) ? (u16)BUFSECS : (u16)secs;
            want  = (u32)chunk * SECSZ;
            if (want > left) want = left;
            rs = (u16)((want + SECSZ - 1) / SECSZ);
            disk_read(lba, rs, databuf);
            if (fwrite(databuf, 1, (size_t)want, fp) != (size_t)want) {
                printf("\n  write failed (DOS disk full?)\n");
                return -1;
            }
            left -= want; lba += chunk; secs -= chunk;
            t_bytes += want;
            progress(name, size - left, size);
        }
        if (left) c = fat_get(n);
    }
    return 0;
}

/* file -> stick. Returns first cluster (0 for empty file), or 1 on error. */
static u32 file_to_chain(FILE *fp, u32 size, const char *name)
{
    u32 left = size, need, first = 0, prev = 0, c, run, i, lba, secs, want, maxrun, bytes;
    u16 chunk, ws;

    need = size / v_clusbytes + (size % v_clusbytes ? 1 : 0);
    if (v_free != 0xFFFFFFFFUL && (long)need > (long)v_free + v_freedelta) {
        printf("  not enough room on the stick\n");
        return 1;
    }
    maxrun = v_spc <= BUFSECS ? BUFSECS / v_spc : 1;
    while (need) {
        c = fat_find_free();
        if (!c) {
            printf("\n  stick is full\n");
            if (first) fat_free_chain(first);
            fat_flush();
            return 1;
        }
        run = 1;
        while (run < maxrun && run < need && c + run <= v_maxclus && fat_get(c + run) == 0) run++;
        for (i = 0; i < run; i++) fat_set(c + i, i + 1 < run ? c + i + 1 : fat_eocval());
        if (prev) fat_set(prev, c); else first = c;
        prev = c + run - 1;
        v_hint = prev + 1;
        v_freedelta -= (long)run;
        need -= run;

        lba = clus2lba(c);
        secs = run * v_spc;
        while (secs && left) {
            chunk = (secs > BUFSECS) ? (u16)BUFSECS : (u16)secs;
            bytes = (u32)chunk * SECSZ;
            want  = left < bytes ? left : bytes;
            if (fread(databuf, 1, (size_t)want, fp) != (size_t)want) {
                printf("\n  read error on DOS file\n");
                fat_free_chain(first); fat_flush();
                return 1;
            }
            if (want < bytes) memset(databuf + (size_t)want, 0, (size_t)(bytes - want));
            ws = (u16)((want + SECSZ - 1) / SECSZ);
            disk_write(lba, ws, databuf);
            left -= want; lba += chunk; secs -= chunk;
            t_bytes += want;
            progress(name, size - left, size);
        }
    }
    fat_flush();
    return first;
}

/* ------------------------------------------------------------------ */
/*  Commands                                                          */
/* ------------------------------------------------------------------ */

static DENT g_d;            /* big struct: keep it off the stack */

#ifndef USBXGUI             /* the GUI has its own versions of these */

static void print_free(void)
{
    if (v_free != 0xFFFFFFFFUL) {
        u32 kb = (v_free / 2) * v_spc + (v_free & 1) * (v_spc / 2);
        if (kb >= 10240UL) printf("%10lu MB free\n", UL(kb / 1024));
        else               printf("%10lu KB free\n", UL(kb));
    }
}

static const char *drive_name(void)
{
    static char b[8];
    if (g_usb) return "USB";
    sprintf(b, "%02Xh", g_drive);
    return b;
}

static void cmd_info(void)
{
    u32 mb = v_clusters * v_spc / 2048UL;
    printf("Drive %s  %s  %lu sectors%s%s\n", drive_name(), g_usb ? "direct" : d_ext ? "LBA" : "CHS",
           UL(d_total), d_iface[0] ? "  interface " : "", d_iface);
    printf("Volume    \"%s\"  serial %04lX-%04lX\n", v_label,
           UL(v_serial >> 16), UL(v_serial & 0xFFFF));
    printf("Type      FAT%d, starts at sector %lu\n", v_type, UL(v_start));
    printf("Cluster   %lu bytes, %lu clusters (about %lu MB)\n",
           UL(v_clusbytes), UL(v_clusters), UL(mb));
    print_free();
}

static void cmd_dir(const char *path)
{
    DIT it;
    u32 dc, nfiles = 0, ndirs = 0;
    unsigned long total = 0;
    char pat[256];

    if (!resolve_pattern(path, &dc, pat)) die("folder not found on stick");
    printf(" Volume \"%s\" (FAT%d) on drive %s\n", v_label, v_type, drive_name());
    printf(" Directory of %s\n\n", *path ? path : "\\");
    dit_open(&it, dc);
    while (dir_read(&it, &g_d)) {
        if (!dent_match(&g_d, pat)) continue;
        if (strcmp(g_d.sname, ".") == 0 || strcmp(g_d.sname, "..") == 0) continue;
        printf("%-12s ", g_d.sname);
        if (g_d.attr & 0x10) { printf("   <DIR>  "); ndirs++; }
        else { printf("%10lu", UL(g_d.size)); nfiles++; total += g_d.size; }
        printf("  %02u-%02u-%04u %2u:%02u",
               (g_d.date >> 5) & 15, g_d.date & 31, (g_d.date >> 9) + 1980,
               g_d.time >> 11, (g_d.time >> 5) & 63);
        if (g_d.haslong) printf("  %s", g_d.lname);
        printf("\n");
    }
    printf("%10lu file(s) %12lu bytes\n%10lu dir(s)  ", UL(nfiles), total, UL(ndirs));
    if (v_free != 0xFFFFFFFFUL) print_free(); else printf("\n");
}

#endif /* USBXGUI */

static int local_isdir(const char *p)
{
    size_t n = strlen(p);
    if (n == 0) return 1;
    if (p[n-1] == '\\' || p[n-1] == '/' || p[n-1] == ':') return 1;
    if (strcmp(p, ".") == 0 || strcmp(p, "..") == 0) return 1;
#ifndef HOSTTEST
    {
        struct find_t f;
        if (_dos_findfirst(p, _A_SUBDIR | _A_HIDDEN | _A_SYSTEM | _A_RDONLY, &f) == 0
            && (f.attrib & _A_SUBDIR)) return 1;
    }
#endif
    return 0;
}

#ifndef USBXGUI
static void cmd_get(const char *src, const char *dest)
{
    DIT it;
    u32 dc;
    char pat[256], out[200];
    int dir = local_isdir(dest), count = 0, failed = 0;
    FILE *fp;

    if (!resolve_pattern(src, &dc, pat)) die("folder not found on stick");
    dit_open(&it, dc);
    while (dir_read(&it, &g_d)) {
        if (g_d.attr & 0x10) continue;
        if (!dent_match(&g_d, pat)) continue;
        if (!dir && count > 0) { printf("Destination must be a folder for several files\n"); break; }
        if (dir) {
            size_t n = strlen(dest);
            strcpy(out, dest);
            if (n && dest[n-1] != '\\' && dest[n-1] != '/' && dest[n-1] != ':') strcat(out,
#ifdef HOSTTEST
                "/"
#else
                "\\"
#endif
            );
            strcat(out, g_d.sname);
        } else strcpy(out, dest);
        count++;

        fp = fopen(out, "rb");
        if (fp) {
            char q[240];
            fclose(fp);
            sprintf(q, "  %s exists. Overwrite", out);
            if (!ask(q)) continue;
        }
        fp = fopen(out, "wb");
        if (!fp) { printf("  can't create %s\n", out); failed++; continue; }
        printf("  %-12s -> %s", g_d.sname, out);
        if (g_d.haslong) printf("   (%s)", g_d.lname);
        printf("\n");
        if (chain_to_file(g_d.clus, g_d.size, fp, g_d.sname)) failed++;
        fflush(fp);
#ifndef HOSTTEST
        _dos_setftime(fileno(fp), g_d.date, g_d.time);
#endif
        fclose(fp);
        if (g_d.size >= 65536UL) printf("\r%40s\r", "");
    }
    if (!count) printf("No matching files on the stick\n");
    else printf("%d file(s) copied%s\n", count - failed, failed ? ", some FAILED" : "");
}

#endif /* USBXGUI */

static int put_one(const char *path, const char *name, u32 dclus, u16 date, u16 tim)
{
    static DENT d;
    u8 n83[11];
    u8 *e;
    u32 first, size, lba;
    u16 off;
    int exists;
    FILE *fp;

    if (!make_83(name, n83)) { printf("  %s: not an 8.3 name\n", name); return -1; }
    fp = fopen(path, "rb");
    if (!fp) { printf("  can't open %s\n", path); return -1; }
    fseek(fp, 0L, SEEK_END);
    size = (u32)ftell(fp);
    fseek(fp, 0L, SEEK_SET);

    exists = dir_find(dclus, name, &d);
    if (exists && (d.attr & 0x10)) { printf("  %s is a folder on the stick\n", name); fclose(fp); return -1; }
    if (exists) {
        char q[80];
        sprintf(q, "  %s exists on stick. Overwrite", name);
        if (!ask(q)) { fclose(fp); return 0; }
    }

    printf("  %-12s -> stick\n", name);
    first = file_to_chain(fp, size, name);
    fclose(fp);
    if (size >= 65536UL) printf("\r%40s\r", "");
    if (first == 1) return -1;

    if (exists) {
        e = dir_load(d.lba) + d.off;
        { u32 old = d.clus;
          wr16(e + 20, (u16)(first >> 16)); wr16(e + 26, (u16)(first & 0xFFFF));
          wr32(e + 28, size); wr16(e + 22, tim); wr16(e + 24, date); wr16(e + 18, date);
          e[11] |= 0x20; dir_dirty = 1; dir_flush();
          if (clus_ok(old)) { fat_free_chain(old); fat_flush(); }
        }
    } else {
        if (!dir_free_slot(dclus, &lba, &off)) {
            printf("  folder is full\n");
            fat_free_chain(first); fat_flush();
            return -1;
        }
        e = dir_load(lba) + off;
        fill_entry(e, n83, 0x20, first, size, date, tim);
        dir_dirty = 1; dir_flush();
    }
    return 0;
}

static void today(u16 *date, u16 *tim)
{
    time_t t = time(NULL);
    struct tm *tm = localtime(&t);
    *date = (u16)(((tm->tm_year - 80) << 9) | ((tm->tm_mon + 1) << 5) | tm->tm_mday);
    *tim  = (u16)((tm->tm_hour << 11) | (tm->tm_min << 5) | (tm->tm_sec / 2));
}

#ifndef USBXGUI
static void cmd_put(const char *pattern, const char *dstdir)
{
    u32 dc;
    int count = 0, failed = 0;

    if (!resolve_dir(dstdir, &dc)) die("folder not found on stick (use MD to make it)");
#ifdef HOSTTEST
    {
        const char *b = strrchr(pattern, '/');
        u16 dt, tm;
        today(&dt, &tm);
        b = b ? b + 1 : pattern;
        count++;
        if (put_one(pattern, b, dc, dt, tm)) failed++;
    }
#else
    {
        struct find_t f;
        char pre[160], full[200];
        const char *p1 = strrchr(pattern, '\\'), *p2 = strrchr(pattern, ':');
        const char *cut = p1 > p2 ? p1 : p2;
        size_t n = cut ? (size_t)(cut - pattern + 1) : 0;
        if (n > 150) n = 150;
        memcpy(pre, pattern, n); pre[n] = 0;
        if (_dos_findfirst(pattern, _A_NORMAL | _A_RDONLY | _A_ARCH, &f) == 0) {
            do {
                if (f.attrib & _A_SUBDIR) continue;
                strcpy(full, pre); strcat(full, f.name);
                count++;
                if (put_one(full, f.name, dc, f.wr_date, f.wr_time)) failed++;
            } while (_dos_findnext(&f) == 0);
        }
    }
#endif
    fsinfo_update();
    if (!count) printf("No matching DOS files\n");
    else printf("%d file(s) copied%s\n", count - failed, failed ? ", some FAILED" : "");
}

static void cmd_del(const char *path)
{
    DIT it;
    u32 dc;
    char pat[256], q[300];
    int count = 0;

    if (!resolve_pattern(path, &dc, pat)) die("folder not found on stick");
    dit_open(&it, dc);
    while (dir_read(&it, &g_d)) {
        if (g_d.attr & 0x10) continue;
        if (!dent_match(&g_d, pat)) continue;
        sprintf(q, "  Delete %s", g_d.haslong ? g_d.lname : g_d.sname);
        if (!ask(q)) continue;
        {
            DIT save = it;           /* dir_erase moves the dir cache */
            u32 c = g_d.clus;
            dir_erase(&g_d);
            if (clus_ok(c)) fat_free_chain(c);
            fat_flush();
            it = save;
        }
        count++;
    }
    fsinfo_update();
    printf("%d file(s) deleted\n", count);
}

static void cmd_md(const char *path)
{
    static DENT d;
    char parent[256], name[64];
    const char *p1 = strrchr(path, '\\'), *p2 = strrchr(path, '/');
    const char *cut = p1 > p2 ? p1 : p2;
    u8 n83[11], *e;
    u32 pc, nc, lba;
    u16 off, dt, tm;
    size_t n;

    if (cut) {
        n = (size_t)(cut - path); if (n > 255) n = 255;
        memcpy(parent, path, n); parent[n] = 0;
        strncpy(name, cut + 1, 63); name[63] = 0;
    } else {
        parent[0] = 0; strncpy(name, path, 63); name[63] = 0;
    }
    if (!make_83(name, n83)) die("folder name must be 8.3 (like PHOTOS or DATA.OLD)");
    if (!resolve_dir(parent, &pc)) die("parent folder not found on stick");
    if (dir_find(pc, name, &d)) die("that name already exists");

    nc = fat_find_free();
    if (!nc) die("stick is full");
    fat_set(nc, fat_eocval());
    v_freedelta--; v_hint = nc + 1;
    fat_flush();
    zero_cluster(nc);

    today(&dt, &tm);
    memset(databuf, 0, SECSZ);
    { u8 dot[11];
      memset(dot, ' ', 11); dot[0] = '.';
      fill_entry(databuf, dot, 0x10, nc, 0, dt, tm);
      dot[1] = '.';
      fill_entry(databuf + 32, dot, 0x10, pc, 0, dt, tm); }
    disk_write(clus2lba(nc), 1, databuf);

    if (!dir_free_slot(pc, &lba, &off)) {
        fat_free_chain(nc); fsinfo_update();
        die("parent folder is full");
    }
    e = dir_load(lba) + off;
    fill_entry(e, n83, 0x10, nc, 0, dt, tm);
    dir_dirty = 1; dir_flush();
    fsinfo_update();
    printf("Folder %s made\n", name);
}

#endif /* USBXGUI */

/* ------------------------------------------------------------------ */
/*  Drive selection                                                   */
/* ------------------------------------------------------------------ */

static int bios_hd_count(void)
{
#ifdef HOSTTEST
    return 2;
#else
    u8 far *bda = (u8 far *)0x00400075L;
    return *bda;
#endif
}

#if !defined(HOSTTEST) && !defined(USBXGUI)
static void on_break(int sig)
{
    (void)sig;
    usb_close();
    printf("\nUSBXFER: stopped\n");
    exit(3);
}
#endif

#ifndef HOSTTEST
/* Talk to the stick through the USB controller (no BIOS help) */
static int usb_attach(int verbose, char *msg)
{
    if (usb_open(g_ctl, verbose, g_usbfl)) { sprintf(msg, "direct USB: %s", usb_err); return -1; }
    {   static int once = 0;
        if (!once) { atexit(usb_close); once = 1; }
    }
#ifndef USBXGUI
    signal(SIGINT, on_break);
#endif
    g_usb = 1;
    g_drive = 0x100;
    d_ext = 1;
    d_total = usb_sectors();
    strcpy(d_iface, strncmp(usb_where, "USB 2.0", 7) == 0 ? "EHCI" : "UHCI");
    fat_lba = dir_lba = NOCACHE;
    return vol_mount(msg);
}
#endif

#ifndef USBXGUI
static void cmd_drives(void)
{
    int n = bios_hd_count(), d;
    char msg[80];
    if (n < 2) n = 2;
    printf("BIOS reports %d hard disk(s)\n\n", bios_hd_count());
    for (d = 0x00; d <= 0x01; d++) {
        if (disk_open(d)) continue;
        printf("  %02Xh  %6lu KB  %s  %-5s", d, UL(d_total / 2),
               d_ext ? "LBA" : "CHS", d_iface[0] ? d_iface : "-");
        if (d_total <= 5760UL && !d_ext) { printf("  floppy drive %c:\n", 'A' + d); continue; }
        g_drive = d;
        fat_lba = dir_lba = NOCACHE;
        if (vol_mount(msg) == 0) printf("  FAT%d  \"%s\"  (stick as floppy)", v_type, v_label);
        else printf("  (%s)", msg);
        printf("\n");
    }
    for (d = 0x80; d < 0x80 + n && d < 0x90; d++) {
        if (disk_open(d)) { if (d > 0x80) printf("  %02Xh  (no answer)\n", d); continue; }
        printf("  %02Xh  %6lu MB  %s  %-5s", d, UL(d_total / 2048UL),
               d_ext ? "LBA" : "CHS", d_iface[0] ? d_iface : "-");
        g_drive = d;
        fat_lba = dir_lba = NOCACHE;
        if (vol_mount(msg) == 0) printf("  FAT%d  \"%s\"", v_type, v_label);
        else printf("  (%s)", msg);
        if (d == 0x80) printf("  <- your boot disk (C:)");
        else if (strcmp(d_iface, "USB") != 0) printf("  <- not USB, skipped");
        printf("\n");
    }
#ifndef HOSTTEST
    printf("\nUSB controllers (direct):\n");
    if (usb_attach(1, msg) == 0)
        printf("  USB  %6lu MB  %s  FAT%d  \"%s\"\n", UL(d_total / 2048UL), usb_where, v_type, v_label);
    else if (g_usb)
        printf("  USB  %6lu MB  %s  (%s)\n", UL(d_total / 2048UL), usb_where, msg);
    else
        printf("  %s\n", msg);
#endif
}

static void pick_drive(void)
{
    char msg[80];
    int n, d, skipped = 0;

#ifndef HOSTTEST
    if (g_force_usb) {
        if (usb_attach(1, msg)) { printf("USBXFER: %s\n", msg); exit(2); }
        return;
    }
#endif
    if (g_drive >= 0) {
        if (disk_open(g_drive)) die("that BIOS drive doesn't answer");
        if (vol_mount(msg)) { printf("USBXFER: drive %02Xh: %s\n", g_drive, msg); exit(2); }
        return;
    }
    n = bios_hd_count();
    if (n < 2) n = 2;
    for (d = 0x81; d < 0x80 + n && d < 0x90; d++) {
        if (disk_open(d)) continue;
        if (strcmp(d_iface, "USB") != 0) { skipped = d; continue; }   /* a real disk/CF card */
        g_drive = d;
        fat_lba = dir_lba = NOCACHE;
        if (vol_mount(msg) == 0) return;
    }
    /* some BIOSes present a USB stick as a floppy (A: or B:) */
    for (d = 0x00; d <= 0x01; d++) {
        if (disk_open(d)) continue;
        if (d_total <= 5760UL && !d_ext) continue;   /* a real floppy drive */
        g_drive = d;
        fat_lba = dir_lba = NOCACHE;
        if (vol_mount(msg) == 0) return;
    }
#ifndef HOSTTEST
    /* BIOS doesn't offer the stick: drive the USB controller ourselves */
    if (usb_attach(0, msg) == 0) return;
    printf("USBXFER: no USB stick found.\n  %s\n", msg);
#else
    printf("USBXFER: no USB stick found.\n");
#endif
    if (skipped)
        printf("  (BIOS drive %02Xh is a hard disk or CF card, not a USB stick -\n"
               "   use /D:%02X if you really want USBXFER to use it)\n", skipped, skipped);
    printf("  - Use a USB port on the PC that isn't used by the keyboard/mouse.\n"
           "  - Run USBXFER DRIVES and USBDIAG to see what the PC reports.\n");
    exit(2);
}

/* ------------------------------------------------------------------ */
/*  Main                                                              */
/* ------------------------------------------------------------------ */

static void usage(void)
{
    printf("USBXFER " VERSION " - copy files to/from a USB stick (FAT16/FAT32) under DOS\n\n"
           "  USBXFER DRIVES                     list BIOS drives\n"
           "  USBXFER INFO                       stick volume details\n"
           "  USBXFER DIR [\\path\\pattern]        list stick files\n"
           "  USBXFER GET \\path\\pattern [dest]   copy stick -> DOS\n"
           "  USBXFER PUT dospattern [\\folder]   copy DOS -> stick\n"
           "  USBXFER DEL \\path\\pattern          delete on stick\n"
           "  USBXFER MD  \\path\\newfolder        make folder on stick\n\n"
           "  /U  use the USB controller directly   /C:n  n-th USB 1.1 controller\n"
           "  /2  USB 2.0 speed (moves the ports to the USB 2.0 controller)\n"
           "  /D:81  use BIOS drive 81h   /P:n  partition n   /Y  don't ask\n\n"
           "Examples:  USBXFER GET \\*.TXT C:\\TEMP\n"
           "           USBXFER PUT C:\\VESA\\*.BMP \\SHOTS\n");
}

int main(int argc, char **argv)
{
    char *args[4];
    int na = 0, i;
    const char *cmd;
    clock_t t0;

    for (i = 1; i < argc; i++) {
        char *a = argv[i];
        if (a[0] == '/' && a[1] && (a[2] == ':' || a[2] == 0) &&
            strchr("DdPpYy?IiUuCc2Zz", a[1])) {
            switch (toupper((u8)a[1])) {
            case 'D': g_drive = (int)strtol(a + 3, NULL, 16); break;
            case 'P': g_part = atoi(a + 3); break;
            case 'Y': g_yes = 1; break;
            case 'U': g_force_usb = 1; break;
            case '2': g_usbfl = 3; g_force_usb = 1; break;
            case 'Z': g_usbfl = 7; g_force_usb = 1; break;    /* test only */
            case 'C': g_ctl = atoi(a + 3); g_force_usb = 1; break;
#ifdef HOSTTEST
            case 'I': g_imgname = a + 3; break;
#endif
            default: usage(); return 0;
            }
        } else if (na < 4) args[na++] = a;
    }
    if (na == 0) { usage(); return 0; }
    cmd = args[0];

    if (ci_eq(cmd, "DRIVES")) { cmd_drives(); return 0; }

    pick_drive();
    t0 = clock();
    t_bytes = 0;

    if (ci_eq(cmd, "INFO")) cmd_info();
    else if (ci_eq(cmd, "DIR")) cmd_dir(na > 1 ? args[1] : "");
    else if (ci_eq(cmd, "GET")) {
        if (na < 2) die("GET needs a file name");
        cmd_get(args[1], na > 2 ? args[2] : "");
    }
    else if (ci_eq(cmd, "PUT") || ci_eq(cmd, "DEL") || ci_eq(cmd, "MD")) {
        if (g_drive == 0x80) die("refusing to write to BIOS drive 80h (your boot disk)");
        if (na < 2) die("missing file name");
        if (ci_eq(cmd, "PUT")) cmd_put(args[1], na > 2 ? args[2] : "");
        else if (ci_eq(cmd, "DEL")) cmd_del(args[1]);
        else cmd_md(args[1]);
    }
    else { usage(); return 1; }

    dir_flush();
    fat_flush();
    if (t_bytes >= 65536UL) {
        double s = (double)(clock() - t0) / CLOCKS_PER_SEC;
        if (s > 0.2) printf("%lu KB in %.1f s (%.0f KB/s)\n", t_bytes >> 10, s, (t_bytes / 1024.0) / s);
    }
    return 0;
}
#endif /* USBXGUI */

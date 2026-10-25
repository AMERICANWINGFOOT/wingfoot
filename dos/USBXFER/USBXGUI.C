/*
 *  USBXGUI.C  -  mouse-driven file manager for USBXFER (MS-DOS 6.22)
 *
 *  Two panels, Norton Commander style:
 *      left  = a DOS folder          right = the USB stick (FAT16/FAT32)
 *  Mouse (INT 33h - USBMOUSE, MOUSE.COM, CTMOUSE ...) and keyboard.
 *
 *  It is USBXFER with a screen on top: this file #includes USBXFER.C, so
 *  the stick is reached exactly the same way (BIOS INT 13h, or directly
 *  through the UHCI/EHCI controller with USBDRV.C).
 *
 *  Options (same meaning as USBXFER):
 *      /U  direct USB    /2  USB 2.0    /C:n  n-th USB 1.1 controller
 *      /D:81  BIOS drive  /P:n  partition  /Y  don't ask before overwriting
 *
 *  Build (QuickC 2.5):   MAKE.BAT   (USBXGUI.C + USBDRV.C + IO32.OBJ)
 *  Build (Open Watcom):  wcl -bt=dos -ms -ox -k10240 usbxgui.c usbdrv.c io32.obj
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <setjmp.h>
#include <malloc.h>
#include <direct.h>
#include <dos.h>
#include <conio.h>

#define USBXGUI
#define GUIVER "1.0"

/* hooks USBXFER.C calls instead of printing / asking / exiting */
int  gui_printf(const char *fmt, ...);
int  gui_ask(const char *q);
void gui_die(const char *msg);
void gui_progress(const char *name, unsigned long done, unsigned long total);

#define printf gui_printf
#include "USBXFER.C"
#undef printf

/* ------------------------------------------------------------------ */
/*  Screen                                                            */
/* ------------------------------------------------------------------ */

#define SCRW 80
#define SCRH 25

/* colours */
#define A_PANEL   0x1B      /* light cyan on blue  */
#define A_DIR     0x1F      /* white on blue       */
#define A_MARK    0x1E      /* yellow on blue      */
#define A_BAR     0x30      /* black on cyan       */
#define A_BARMARK 0x3E      /* yellow on cyan      */
#define A_TITLE   0x30
#define A_STATUS  0x0F
#define A_ERROR   0x0C
#define A_INFO    0x0E
#define A_FNUM    0x07
#define A_FLBL    0x30
#define A_DLG     0x70
#define A_DLGERR  0x4F
#define A_BTN     0x20
#define A_BTNSEL  0x2F
#define A_EDIT    0x1F

static unsigned short far *vram = (unsigned short far *)0xB8000000L;

static void putcell(int x, int y, int ch, int at)
{
    if (x < 0 || y < 0 || x >= SCRW || y >= SCRH) return;
    vram[y * SCRW + x] = (unsigned short)(((unsigned)at << 8) | (u8)ch);
}

static void fillc(int x, int y, int w, int ch, int at)
{
    while (w-- > 0) putcell(x++, y, ch, at);
}

/* write s at x,y; if w > 0 pad with blanks / cut to exactly w columns */
static void puts_at(int x, int y, const char *s, int at, int w)
{
    int i = 0;
    while (s[i] && (w <= 0 || i < w)) { putcell(x + i, y, (u8)s[i], at); i++; }
    if (w > 0) fillc(x + i, y, w - i, ' ', at);
}

static void box(int x, int y, int w, int h, int at)
{
    int i;
    putcell(x, y, 0xC9, at); putcell(x + w - 1, y, 0xBB, at);
    putcell(x, y + h - 1, 0xC8, at); putcell(x + w - 1, y + h - 1, 0xBC, at);
    fillc(x + 1, y, w - 2, 0xCD, at);
    fillc(x + 1, y + h - 1, w - 2, 0xCD, at);
    for (i = 1; i < h - 1; i++) {
        putcell(x, y + i, 0xBA, at);
        fillc(x + 1, y + i, w - 2, ' ', at);
        putcell(x + w - 1, y + i, 0xBA, at);
    }
}

/* saved screens (for dialogs drawn on top of each other) */
#define NSAVE 3
static unsigned short far *g_save[NSAVE];
static int g_nsave = 0;

/* ------------------------------------------------------------------ */
/*  Mouse (INT 33h)                                                   */
/* ------------------------------------------------------------------ */

static int m_present = 0;
static int m_hidden  = 0;       /* how many m_hide() calls are open */

static void m_call(union REGS *r) { int86(0x33, r, r); }

static void m_hide(void)
{
    union REGS r;
    m_hidden++;
    if (!m_present) return;
    r.x.ax = 2; m_call(&r);
}

static void m_show(void)
{
    union REGS r;
    if (m_hidden > 0) m_hidden--;
    if (!m_present) return;
    r.x.ax = 1; m_call(&r);
}

static int m_init(void)
{
    union REGS r;
    if (*(unsigned long far *)(0x33 * 4L) == 0) return 0;   /* no driver */
    r.x.ax = 0; m_call(&r);
    return r.x.ax == 0xFFFF;
}

/* presses of button b since last call; position of the last one (cells) */
static int m_press(int b, int *col, int *row)
{
    union REGS r;
    if (!m_present) return 0;
    r.x.ax = 5; r.x.bx = (unsigned)b; m_call(&r);
    if (!r.x.bx) return 0;
    *col = (int)(r.x.cx / 8);
    *row = (int)(r.x.dx / 8);
    return (int)r.x.bx;
}

static void m_flush(void)
{
    int c, r;
    m_press(0, &c, &r);
    m_press(1, &c, &r);
}

static unsigned long ticks(void) { return *(unsigned long far *)0x0040006CL; }

/* screen save/restore - always with the mouse cursor hidden */
static void scr_save(void)
{
    if (g_nsave >= NSAVE) return;
    m_hide();
    _fmemcpy(g_save[g_nsave++], vram, SCRW * SCRH * 2);
    m_show();
}

static void scr_restore(void)
{
    if (g_nsave <= 0) return;
    m_hide();
    _fmemcpy(vram, g_save[--g_nsave], SCRW * SCRH * 2);
    m_show();
}

/* ------------------------------------------------------------------ */
/*  Events                                                            */
/* ------------------------------------------------------------------ */

#define K_F1    0x13B
#define K_F2    0x13C
#define K_F3    0x13D
#define K_F4    0x13E
#define K_F5    0x13F
#define K_F6    0x140
#define K_F7    0x141
#define K_F8    0x142
#define K_F9    0x143
#define K_F10   0x144
#define K_HOME  0x147
#define K_UP    0x148
#define K_PGUP  0x149
#define K_LEFT  0x14B
#define K_RIGHT 0x14D
#define K_END   0x14F
#define K_DOWN  0x150
#define K_PGDN  0x151
#define K_INS   0x152
#define K_DEL   0x153
#define K_ALTX  0x12D

#define EV_KEY   1
#define EV_LEFT  2
#define EV_RIGHT 3

typedef struct { int type, key, x, y, dbl; } EV;

static int get_key(void)
{
    int c = getch();
    if (c == 0 || c == 0xE0) return 0x100 + getch();
    return c;
}

static void get_event(EV *ev)
{
    static unsigned long lt = 0;
    static int lx = -1, ly = -1;
    int x, y, n;
    memset(ev, 0, sizeof(*ev));
    for (;;) {
        if (kbhit()) { ev->type = EV_KEY; ev->key = get_key(); return; }
        if ((n = m_press(0, &x, &y)) != 0) {
            unsigned long t = ticks();
            ev->type = EV_LEFT; ev->x = x; ev->y = y;
            ev->dbl = (y == ly && x / 40 == lx / 40 && t - lt <= 9UL);
            if (n >= 2) ev->dbl = 1;      /* two clicks between polls */
            lt = ev->dbl ? 0 : t; lx = x; ly = y;
            return;
        }
        if (m_press(1, &x, &y)) { ev->type = EV_RIGHT; ev->x = x; ev->y = y; return; }
    }
}

/* ------------------------------------------------------------------ */
/*  Status line and hooks for USBXFER.C                               */
/* ------------------------------------------------------------------ */

static char g_status[81];
static int  g_status_at = A_STATUS;
static char g_lastmsg[120];     /* last thing USBXFER.C printed */
static char g_errmsg[120];      /* set by gui_die               */
static jmp_buf g_jmp;
static int  g_cancel = 0;
static int  g_yes_cmd = 0;      /* /Y on the command line       */
static int  g_in_op = 0;        /* a copy/delete is running     */

static void status(int at, const char *fmt, ...)
{
    va_list ap;
    char b[200];
    va_start(ap, fmt);
    vsprintf(b, fmt, ap);
    va_end(ap);
    b[79] = 0;
    strcpy(g_status, b);
    g_status_at = at;
    m_hide();
    puts_at(0, 23, " ", at, 1);
    puts_at(1, 23, g_status, at, 79);
    m_show();
}

int gui_printf(const char *fmt, ...)
{
    va_list ap;
    char b[300];
    char *p, *e;
    va_start(ap, fmt);
    vsprintf(b, fmt, ap);
    va_end(ap);
    for (p = b; *p == ' ' || *p == '\r' || *p == '\n'; p++) ;
    e = p + strlen(p);
    while (e > p && (e[-1] == ' ' || e[-1] == '\r' || e[-1] == '\n')) *--e = 0;
    if (*p) { strncpy(g_lastmsg, p, sizeof(g_lastmsg) - 1); g_lastmsg[sizeof(g_lastmsg) - 1] = 0; }
    return 0;
}

void gui_die(const char *msg)
{
    strncpy(g_errmsg, msg, sizeof(g_errmsg) - 1);
    g_errmsg[sizeof(g_errmsg) - 1] = 0;
    longjmp(g_jmp, 1);
}

/* critical-error handler: never "Abort, Retry, Fail?" on our screen */
#ifdef __WATCOMC__
static int __far crit_handler(unsigned deverr, unsigned errcode, unsigned __far *devhdr)
{
    (void)deverr; (void)errcode; (void)devhdr;
    return _HARDERR_FAIL;
}
#else
static void _far crit_handler(unsigned deverr, unsigned errcode, unsigned _far *devhdr)
{
    (void)deverr; (void)errcode; (void)devhdr;
    _hardresume(_HARDERR_FAIL);
}
#endif

/* ------------------------------------------------------------------ */
/*  Dialogs                                                           */
/* ------------------------------------------------------------------ */

#define MAXBTN 16

typedef struct { int x, y, w; char label[16]; } BTN;

static int split_btns(const char *btns, BTN *b)
{
    int n = 0, k;
    while (*btns && n < MAXBTN) {
        k = 0;
        while (*btns && *btns != '|' && k < 15) b[n].label[k++] = *btns++;
        b[n].label[k] = 0;
        if (*btns == '|') btns++;
        b[n].w = k + 4;
        n++;
    }
    return n;
}

static void draw_btns(BTN *b, int n, int focus)
{
    int i;
    char t[24];
    for (i = 0; i < n; i++) {
        sprintf(t, "[ %s ]", b[i].label);
        puts_at(b[i].x, b[i].y, t, i == focus ? A_BTNSEL : A_BTN, 0);
    }
}

static int place_btns(BTN *b, int n, int x, int w, int y)
{
    int i, tot = 0, cx;
    for (i = 0; i < n; i++) tot += b[i].w + (i ? 2 : 0);
    cx = x + (w - tot) / 2;
    for (i = 0; i < n; i++) { b[i].x = cx; b[i].y = y; cx += b[i].w + 2; }
    return tot;
}

static int btn_hit(BTN *b, int n, int x, int y)
{
    int i;
    for (i = 0; i < n; i++)
        if (y == b[i].y && x >= b[i].x && x < b[i].x + b[i].w) return i;
    return -1;
}

static int btn_key(BTN *b, int n, int key)
{
    int i;
    if (key >= 0x100) return -1;
    for (i = 0; i < n; i++)
        if (toupper(key) == toupper((u8)b[i].label[0])) return i;
    return -1;
}

/* Message box. msg may hold several lines split by '\n'.
   Returns the button number; Enter = focused button, Esc = last one. */
static int dialog(const char *title, const char *msg, const char *btns, int at)
{
    BTN b[MAXBTN];
    char line[12][72];
    int nl = 0, n, w, h, x, y, i, k, focus = 0, tot, r;
    const char *p = msg;
    EV ev;

    while (*p && nl < 12) {
        k = 0;
        while (*p && *p != '\n' && k < 70) line[nl][k++] = *p++;
        line[nl][k] = 0;
        while (*p && *p != '\n') p++;
        if (*p == '\n') p++;
        nl++;
    }
    n = split_btns(btns, b);
    w = (int)strlen(title) + 8;
    for (i = 0; i < nl; i++) if ((int)strlen(line[i]) + 6 > w) w = (int)strlen(line[i]) + 6;
    tot = 0; for (i = 0; i < n; i++) tot += b[i].w + 2;
    if (tot + 4 > w) w = tot + 4;
    if (w < 34) w = 34;
    if (w > 78) w = 78;
    h = nl + 5;
    x = (SCRW - w) / 2; y = (SCRH - h) / 2 - 1;

    scr_save();
    m_hide();
    box(x, y, w, h, at);
    if (*title) {
        char t[80];
        sprintf(t, " %s ", title);
        puts_at(x + (w - (int)strlen(t)) / 2, y, t, at, 0);
    }
    for (i = 0; i < nl; i++) puts_at(x + 3, y + 2 + i, line[i], at, 0);
    place_btns(b, n, x, w, y + h - 2);
    draw_btns(b, n, focus);
    m_show();
    m_flush();

    for (;;) {
        get_event(&ev);
        r = -1;
        if (ev.type == EV_KEY) {
            if (ev.key == 13) r = focus;
            else if (ev.key == 27) r = n - 1;
            else if (ev.key == 9 || ev.key == K_RIGHT) focus = (focus + 1) % n;
            else if (ev.key == K_LEFT || ev.key == 0x10F) focus = (focus + n - 1) % n;
            else r = btn_key(b, n, ev.key);
            if (r < 0) { m_hide(); draw_btns(b, n, focus); m_show(); }
        } else if (ev.type == EV_LEFT) {
            r = btn_hit(b, n, ev.x, ev.y);
        }
        if (r >= 0) break;
    }
    scr_restore();
    return r;
}

static void msgbox(const char *title, const char *msg)
{
    dialog(title, msg, "OK", A_DLG);
}

static void errbox(const char *msg)
{
    dialog("Problem", msg, "OK", A_DLGERR);
}

/* Line input. Returns 1 = OK, 0 = cancelled. */
static int input_box(const char *title, const char *prompt, char *buf, int maxlen)
{
    BTN b[2];
    int w = 50, h = 8, x, y, len, r = -1;
    EV ev;

    len = (int)strlen(buf);
    x = (SCRW - w) / 2; y = 8;
    split_btns("OK|Cancel", b);
    scr_save();
    m_hide();
    box(x, y, w, h, A_DLG);
    { char t[80]; sprintf(t, " %s ", title); puts_at(x + (w - (int)strlen(t)) / 2, y, t, A_DLG, 0); }
    puts_at(x + 3, y + 2, prompt, A_DLG, 0);
    place_btns(b, 2, x, w, y + h - 2);
    draw_btns(b, 2, -1);
    m_show();
    m_flush();
    for (;;) {
        m_hide();
        puts_at(x + 3, y + 3, buf, A_EDIT, maxlen + 1);
        putcell(x + 3 + len, y + 3, '_', A_EDIT);
        m_show();
        get_event(&ev);
        if (ev.type == EV_KEY) {
            if (ev.key == 13) { r = 1; break; }
            if (ev.key == 27) { r = 0; break; }
            if (ev.key == 8) { if (len) buf[--len] = 0; }
            else if (ev.key >= 32 && ev.key < 127 && len < maxlen) { buf[len++] = (char)ev.key; buf[len] = 0; }
        } else if (ev.type == EV_LEFT) {
            int k = btn_hit(b, 2, ev.x, ev.y);
            if (k == 0) { r = 1; break; }
            if (k == 1) { r = 0; break; }
        }
    }
    scr_restore();
    return r;
}

/* progress window (drawn while a copy/delete runs) */
static int  pg_on = 0;
static clock_t pg_t0, pg_last;
static unsigned long pg_files = 0;
#define PGX 10
#define PGY 8
#define PGW 60

static void pg_open(const char *title)
{
    char t[40];
    scr_save();
    m_hide();
    box(PGX, PGY, PGW, 8, A_DLG);
    sprintf(t, " %s ", title);
    puts_at(PGX + (PGW - (int)strlen(t)) / 2, PGY, t, A_DLG, 0);
    puts_at(PGX + 3, PGY + 6, "Esc = stop after this file", A_DLG, 0);
    m_show();
    pg_on = 1;
    pg_t0 = pg_last = clock();
    pg_files = 0;
}

static void pg_close(void)
{
    if (!pg_on) return;
    pg_on = 0;
    scr_restore();
}

static void pg_name(const char *verb, const char *name)
{
    char t[80];
    if (!pg_on) return;
    sprintf(t, "%s %.45s", verb, name);
    m_hide();
    puts_at(PGX + 3, PGY + 2, t, A_DLG, PGW - 6);
    m_show();
}

static void pg_check_esc(void)
{
    while (kbhit()) {
        int k = get_key();
        if (k == 27) {
            g_cancel = 1;
            if (pg_on) { m_hide(); puts_at(PGX + 3, PGY + 6, "Stopping after this file...", A_DLG | 0x04, PGW - 6); m_show(); }
        }
    }
}

/* KB per second, integer maths only (keeps the float library out) */
static unsigned long kb_per_s(void)
{
    unsigned long ms = (unsigned long)(clock() - pg_t0) * 1000UL / CLOCKS_PER_SEC;
    if (ms < 200) return 0;
    if (t_bytes < 4000000UL) return (t_bytes * 1000UL / 1024UL) / ms;
    return (t_bytes / 1024UL) / (ms / 1000UL ? ms / 1000UL : 1);
}

static void pg_stats(void)
{
    char t[80];
    unsigned long sp = kb_per_s();
    if (!pg_on) return;
    if (sp)
        sprintf(t, "Files done: %lu    %lu KB    %lu KB/s", pg_files, t_bytes >> 10, sp);
    else
        sprintf(t, "Files done: %lu    %lu KB", pg_files, t_bytes >> 10);
    m_hide();
    puts_at(PGX + 3, PGY + 4, t, A_DLG, PGW - 6);
    m_show();
}

void gui_progress(const char *name, unsigned long done, unsigned long total)
{
    clock_t now = clock();
    int bw = PGW - 6, fill, i;
    (void)name;
    pg_check_esc();
    if (!pg_on) return;
    if (done < total && now - pg_last < CLOCKS_PER_SEC / 4 && now >= pg_last) return;
    pg_last = now;
    if (!total) fill = bw;
    else if (total < 65536UL) fill = (int)(done * bw / total);
    else fill = (int)((done >> 8) * bw / ((total >> 8) + 1));
    m_hide();
    for (i = 0; i < bw; i++) putcell(PGX + 3 + i, PGY + 3, i < fill ? 0xDB : 0xB0, A_DLG);
    m_show();
    pg_stats();
}

int gui_ask(const char *q)
{
    char t[200];
    int r;
    while (*q == ' ') q++;
    sprintf(t, "%s?", q);
    r = dialog("Confirm", t, "Yes|No|All|Cancel", A_DLG);
    if (r == 3) { g_cancel = 1; return 'N'; }
    return "YNA"[r];
}

/* ------------------------------------------------------------------ */
/*  Panels                                                            */
/* ------------------------------------------------------------------ */

#define MAXENT  500
#define LROWS   18              /* list rows: screen rows 2..19 */
#define LTOP    2
#define MAXDEPTH 8

typedef struct {
    char sname[13];
    char lname[37];
    u8   attr, sel;
    u32  size, clus;
    u16  date, time;
} ENT;

typedef struct {
    ENT far *e;
    int  n, top, cur, trunc;
    int  nsel;
    u32  selbytes;
    int  isusb;
    int  x;
    char path[130];
    char err[60];
    char freetxt[24];
} PANEL;

static PANEL g_p[2];
static int   g_act = 0;
static int   stick_ok = 0;
static char  stick_msg[90];
static u32   g_sdc = 0;          /* stick folder being shown */
static int   g_drive_cmd = -1;
static DENT  dpool[MAXDEPTH + 2];

static int is_dotdot(const char far *s) { return s[0] == '.' && s[1] == '.' && s[2] == 0; }

static int far_ci_cmp(const char far *a, const char far *b)
{
    int ca, cb;
    for (;;) {
        ca = toupper((u8)*a); cb = toupper((u8)*b);
        if (ca != cb || !ca) return ca - cb;
        a++; b++;
    }
}

static int ent_cmp(ENT far *a, ENT far *b)
{
    int da, db;
    if (is_dotdot(a->sname)) return -1;
    if (is_dotdot(b->sname)) return 1;
    da = (a->attr & 0x10) != 0; db = (b->attr & 0x10) != 0;
    if (da != db) return db - da;
    return far_ci_cmp(a->lname[0] ? a->lname : a->sname, b->lname[0] ? b->lname : b->sname);
}

static void sort_panel(PANEL *p)
{
    int gap, i, j;
    ENT t;
    for (gap = p->n / 2; gap > 0; gap /= 2)
        for (i = gap; i < p->n; i++) {
            _fmemcpy(&t, &p->e[i], sizeof(ENT));
            for (j = i; j >= gap && ent_cmp(&p->e[j - gap], (ENT far *)&t) > 0; j -= gap)
                _fmemcpy(&p->e[j], &p->e[j - gap], sizeof(ENT));
            _fmemcpy(&p->e[j], &t, sizeof(ENT));
        }
}

static void join(char *out, const char *dir, const char *name)
{
    size_t n = strlen(dir);
    strcpy(out, dir);
    if (n && dir[n - 1] != '\\') strcat(out, "\\");
    strcat(out, name);
}

static int path_is_root(const char *p)
{
    return (p[0] && p[1] == ':' && p[2] == '\\' && p[3] == 0) || strcmp(p, "\\") == 0;
}

/* cut the last component off a path; returns pointer to the removed name */
static void path_up(char *p, char *removed)
{
    char *s = strrchr(p, '\\');
    removed[0] = 0;
    if (!s) return;
    strcpy(removed, s + 1);
    if (s == p || (s == p + 2 && p[1] == ':')) s[1] = 0;
    else *s = 0;
}

static void fmt_size_kb(char *out, unsigned long kb);

static void add_ent(PANEL *p, ENT *t)
{
    if (p->n >= MAXENT) { p->trunc = 1; return; }
    _fmemcpy(&p->e[p->n++], t, sizeof(ENT));
}

static void load_dos(PANEL *p)
{
    struct find_t f;
    char pat[140];
    ENT t;
    int haveup = 0;

    join(pat, p->path, "*.*");
    if (_dos_findfirst(pat, _A_NORMAL | _A_RDONLY | _A_HIDDEN | _A_SYSTEM | _A_SUBDIR | _A_ARCH, &f) != 0) {
        if (!path_is_root(p->path)) {
            /* maybe the folder vanished: fall back to the drive root */
            p->path[3] = 0;
            join(pat, p->path, "*.*");
            if (_dos_findfirst(pat, _A_NORMAL | _A_RDONLY | _A_HIDDEN | _A_SYSTEM | _A_SUBDIR | _A_ARCH, &f) != 0) {
                sprintf(p->err, "Can't read drive %c:", p->path[0]);
                return;
            }
        } else {
            sprintf(p->err, "Can't read drive %c: (no disk?)", p->path[0]);
            return;
        }
    }
    do {
        if (strcmp(f.name, ".") == 0) continue;
        memset(&t, 0, sizeof(t));
        strcpy(t.sname, f.name);
        t.attr = f.attrib; t.size = f.size; t.date = f.wr_date; t.time = f.wr_time;
        if (strcmp(f.name, "..") == 0) haveup = 1;
        add_ent(p, &t);
    } while (_dos_findnext(&f) == 0);
    if (!haveup && !path_is_root(p->path)) {
        memset(&t, 0, sizeof(t)); strcpy(t.sname, ".."); t.attr = 0x10;
        add_ent(p, &t);
    }
}

static void load_usb(PANEL *p)
{
    DIT it;
    ENT t;
    DENT *d = &dpool[0];
    if (!stick_ok) return;
    dit_open(&it, g_sdc);
    while (dir_read(&it, d)) {
        if (strcmp(d->sname, ".") == 0) continue;
        memset(&t, 0, sizeof(t));
        strcpy(t.sname, d->sname);
        if (d->haslong) { strncpy(t.lname, d->lname, 36); t.lname[36] = 0; }
        t.attr = d->attr; t.size = d->size; t.clus = d->clus;
        t.date = d->date; t.time = d->time;
        add_ent(p, &t);
    }
}

static void fix_view(PANEL *p)
{
    if (p->cur >= p->n) p->cur = p->n - 1;
    if (p->cur < 0) p->cur = 0;
    if (p->top > p->cur) p->top = p->cur;
    if (p->cur >= p->top + LROWS) p->top = p->cur - LROWS + 1;
    if (p->top > p->n - LROWS) p->top = p->n - LROWS;
    if (p->top < 0) p->top = 0;
}

/* re-read a panel; keep the cursor on "keep" (short name) if it's there */
static void load_panel(PANEL *p, const char *keep)
{
    int i;
    char cur[13];
    cur[0] = 0;
    if (keep) { strncpy(cur, keep, 12); cur[12] = 0; }
    else if (p->n > 0 && p->cur < p->n) _fstrcpy((char far *)cur, p->e[p->cur].sname);
    p->n = 0; p->trunc = 0; p->nsel = 0; p->selbytes = 0; p->err[0] = 0;
    p->freetxt[0] = 0;
    if (p->isusb) load_usb(p);
    else {
        struct diskfree_t df;
        load_dos(p);
        if (!p->err[0] && _dos_getdiskfree(toupper((u8)p->path[0]) - 'A' + 1, &df) == 0)
            fmt_size_kb(p->freetxt, (unsigned long)df.avail_clusters * df.sectors_per_cluster
                                    * df.bytes_per_sector / 1024UL);
    }
    sort_panel(p);
    p->cur = 0;
    if (cur[0])
        for (i = 0; i < p->n; i++)
            if (far_ci_cmp(p->e[i].sname, (char far *)cur) == 0) { p->cur = i; break; }
    fix_view(p);
}

static void fmt_size_kb(char *out, unsigned long kb)
{
    if (kb >= 10240UL) sprintf(out, "%lu MB", kb / 1024UL);
    else sprintf(out, "%lu KB", kb);
}

static unsigned long stick_free_kb(void)
{
    long fr;
    if (v_free == 0xFFFFFFFFUL) return 0xFFFFFFFFUL;
    fr = (long)v_free + v_freedelta;
    if (fr < 0) fr = 0;
    return (unsigned long)fr * v_spc / 2;
}

static void ent_line(char *out, ENT *e, int isusb)
{
    char nm[40], sz[12];
    const char *src = (isusb && e->lname[0]) ? e->lname : e->sname;
    size_t n = strlen(src);
    if (n > 18) { memcpy(nm, src, 17); nm[17] = '~'; nm[18] = 0; }
    else strcpy(nm, src);
    if (strcmp(e->sname, "..") == 0) strcpy(sz, "  <UP-DIR>");
    else if (e->attr & 0x10) strcpy(sz, "   <DIR>  ");
    else sprintf(sz, "%10lu", UL(e->size));
    if (e->date)
        sprintf(out, " %-18s%s %02u-%02u-%02u", nm, sz,
                (e->date >> 5) & 15, e->date & 31, ((e->date >> 9) + 80) % 100);
    else
        sprintf(out, " %-18s%s", nm, sz);
}

static void draw_panel(int k)
{
    PANEL *p = &g_p[k];
    int x = p->x, i, at, act = (k == g_act);
    char t[90], u[60];
    ENT e;

    m_hide();
    box(x, 1, 40, 23 - 1, A_PANEL);
    putcell(x, 20, 0xC7, A_PANEL); fillc(x + 1, 20, 38, 0xC4, A_PANEL); putcell(x + 39, 20, 0xB6, A_PANEL);

    /* title: path */
    if (p->isusb) sprintf(u, "USB:%s", p->path); else strcpy(u, p->path);
    if (strlen(u) > 32) { sprintf(t, " ...%s ", u + strlen(u) - 29); }
    else sprintf(t, " %s ", u);
    puts_at(x + (40 - (int)strlen(t)) / 2, 1, t, act ? A_TITLE : A_PANEL, 0);
    putcell(x + 38, 1, 0x1E, A_PANEL);          /* page up / down arrows */
    putcell(x + 38, 22, 0x1F, A_PANEL);

    if (p->isusb && !stick_ok) {
        static const char *lines[] = {
            "No USB stick connected", "", "", "",
            "Plug the stick into a USB port pair",
            "that has no keyboard or mouse on it,",
            "then press F2 or click here.", 0 };
        for (i = 0; lines[i]; i++) {
            const char *s = (i == 2) ? stick_msg : lines[i];
            char c[39];
            strncpy(c, s, 38); c[38] = 0;
            puts_at(x + 1 + (38 - (int)strlen(c)) / 2, 5 + i, c, i == 0 ? A_MARK : A_PANEL, 0);
        }
        puts_at(x + 1, 21, "", A_PANEL, 38);
        m_show();
        return;
    }

    for (i = 0; i < LROWS; i++) {
        int idx = p->top + i;
        if (idx >= p->n) { fillc(x + 1, LTOP + i, 38, ' ', A_PANEL); continue; }
        _fmemcpy(&e, &p->e[idx], sizeof(ENT));
        ent_line(t, &e, p->isusb);
        if (act && idx == p->cur) at = e.sel ? A_BARMARK : A_BAR;
        else at = e.sel ? A_MARK : (e.attr & 0x10) ? A_DIR : A_PANEL;
        puts_at(x + 1, LTOP + i, t, at, 38);
    }
    if (p->err[0]) puts_at(x + 2, LTOP + 1, p->err, A_MARK, 0);
    if (p->trunc) puts_at(x + 2, LTOP + LROWS - 1, "(more files than fit - first 500)", A_MARK, 36);

    /* info line */
    if (p->nsel) {
        sprintf(t, " %d selected, %lu KB", p->nsel, (p->selbytes + 1023UL) >> 10);
        puts_at(x + 1, 21, t, A_MARK, 38);
    } else if (p->n > 0) {
        _fmemcpy(&e, &p->e[p->cur], sizeof(ENT));
        sprintf(t, " %.36s", e.lname[0] ? e.lname : e.sname);
        puts_at(x + 1, 21, t, A_PANEL, 38);
        if (!e.lname[0] && e.date) {
            sprintf(t, "%02u:%02u ", e.time >> 11, (e.time >> 5) & 63);
            puts_at(x + 33, 21, t, A_PANEL, 0);
        }
    } else puts_at(x + 1, 21, " (empty)", A_PANEL, 38);

    /* bottom: free space */
    if (p->isusb) {
        unsigned long kb = stick_free_kb();
        char f[20];
        if (kb != 0xFFFFFFFFUL) fmt_size_kb(f, kb); else strcpy(f, "?");
        sprintf(t, " %s  FAT%d  %s free ", v_label[0] ? v_label : "NO NAME", v_type, f);
    } else {
        if (p->freetxt[0]) sprintf(t, " %s free ", p->freetxt);
        else t[0] = 0;
    }
    if (t[0]) puts_at(x + (40 - (int)strlen(t)) / 2, 22, t, A_PANEL, 0);
    m_show();
}

static const char *fkeys[10] = { "Help", "Rescan", "Drive", "Info", "Copy",
                                 "SelAll", "MkDir", "Delete", "", "Quit" };

static void draw_frame(void)
{
    char t[81];
    int i;
    m_hide();
    sprintf(t, " USBXGUI " GUIVER "  -  DOS <-> USB stick");
    puts_at(0, 0, t, A_TITLE, 80);
    if (stick_ok) {
        if (g_usb) sprintf(t, "%.40s ", usb_name[0] ? usb_name : "USB stick");
        else sprintf(t, "BIOS drive %02Xh ", g_drive);
        puts_at(80 - (int)strlen(t), 0, t, A_TITLE, 0);
    }
    for (i = 0; i < 10; i++) {
        sprintf(t, "%2d", i + 1);
        puts_at(i * 8, 24, t, A_FNUM, 2);
        puts_at(i * 8 + 2, 24, fkeys[i], A_FLBL, 6);
    }
    puts_at(0, 23, " ", g_status_at, 1);
    puts_at(1, 23, g_status, g_status_at, 79);
    m_show();
}

static void draw_all(void)
{
    draw_frame();
    draw_panel(0);
    draw_panel(1);
}

/* ------------------------------------------------------------------ */
/*  Stick connection                                                  */
/* ------------------------------------------------------------------ */

static void stick_drop(void)
{
    if (g_usb) usb_close();
    g_usb = 0;
    stick_ok = 0;
    fat_lba = dir_lba = NOCACHE;
    fat_dirty = dir_dirty = 0;
}

static int stick_attach(void)
{
    char msg[90];
    int n, d;

    stick_drop();
    g_sdc = 0;
    strcpy(g_p[1].path, "\\");
    g_p[1].cur = g_p[1].top = 0;
    msg[0] = 0;

    if (g_force_usb) {
        if (usb_attach(0, msg) == 0) { stick_ok = 1; return 0; }
        goto fail;
    }
    if (g_drive_cmd >= 0) {
        if (disk_open(g_drive_cmd)) { strcpy(msg, "that BIOS drive doesn't answer"); goto fail; }
        fat_lba = dir_lba = NOCACHE;
        if (vol_mount(msg) == 0) { stick_ok = 1; return 0; }
        goto fail;
    }
    n = bios_hd_count();
    if (n < 2) n = 2;
    for (d = 0x81; d < 0x80 + n && d < 0x90; d++) {
        if (disk_open(d)) continue;
        if (strcmp(d_iface, "USB") != 0) continue;
        fat_lba = dir_lba = NOCACHE;
        if (vol_mount(msg) == 0) { stick_ok = 1; return 0; }
    }
    for (d = 0x00; d <= 0x01; d++) {
        if (disk_open(d)) continue;
        if (d_total <= 5760UL && !d_ext) continue;
        fat_lba = dir_lba = NOCACHE;
        if (vol_mount(msg) == 0) { stick_ok = 1; return 0; }
    }
    if (usb_attach(0, msg) == 0) { stick_ok = 1; return 0; }
fail:
    stick_drop();
    strncpy(stick_msg, msg, sizeof(stick_msg) - 1);
    stick_msg[sizeof(stick_msg) - 1] = 0;
    return -1;
}

static int stick_writable(void)
{
    if (g_drive == 0x80 && !g_usb) { errbox("Won't write to BIOS drive 80h (your boot disk)."); return 0; }
    return 1;
}

/* ------------------------------------------------------------------ */
/*  Stick <-> DOS operations                                          */
/* ------------------------------------------------------------------ */

static int g_fail = 0;
static char g_failmsg[120];

static void note_fail(const char *m)
{
    g_fail++;
    strncpy(g_failmsg, m, sizeof(g_failmsg) - 1);
    g_failmsg[sizeof(g_failmsg) - 1] = 0;
}

static int dos_exists(const char *path, int *isdir)
{
    struct find_t f;
    if (_dos_findfirst(path, _A_NORMAL | _A_RDONLY | _A_HIDDEN | _A_SYSTEM | _A_SUBDIR | _A_ARCH, &f)) return 0;
    if (isdir) *isdir = (f.attrib & _A_SUBDIR) != 0;
    return 1;
}

/* stick file (in DENT d) -> DOS folder */
static void get_file(DENT *d, const char *destdir)
{
    char out[160], q[200];
    int isdir;
    FILE *fp;

    join(out, destdir, d->sname);
    pg_name("Copying", d->haslong ? d->lname : d->sname);
    if (dos_exists(out, &isdir)) {
        if (isdir) { sprintf(q, "%s is a folder on DOS", out); note_fail(q); return; }
        sprintf(q, "%s exists. Overwrite", out);
        if (!ask(q)) return;
        _dos_setfileattr(out, _A_NORMAL);
    }
    fp = fopen(out, "wb");
    if (!fp) { sprintf(q, "can't create %s", out); note_fail(q); return; }
    if (chain_to_file(d->clus, d->size, fp, d->sname)) note_fail(g_lastmsg);
    fflush(fp);
    _dos_setftime(fileno(fp), d->date, d->time);
    fclose(fp);
    pg_files++;
    pg_stats();
}

/* stick folder (in DENT d) -> DOS folder, with everything in it */
static void get_dir(DENT *d, const char *destdir, int depth)
{
    char out[160];
    DIT it;
    DENT *e;
    int isdir;

    join(out, destdir, d->sname);
    if (!clus_ok(d->clus)) { note_fail("bad folder entry on the stick"); return; }
    if (strlen(out) > 64) { note_fail("path too long for DOS"); return; }
    if (dos_exists(out, &isdir)) {
        if (!isdir) { note_fail("a DOS file has the folder's name"); return; }
    } else if (mkdir(out)) { note_fail("can't make DOS folder"); return; }
    if (depth >= MAXDEPTH) { note_fail("folders nested too deep"); return; }
    e = &dpool[depth + 1];
    dit_open(&it, d->clus);
    while (!g_cancel && dir_read(&it, e)) {
        if (e->sname[0] == '.') continue;
        if (e->attr & 0x10) get_dir(e, out, depth + 1);
        else get_file(e, out);
    }
}

/* make a folder on the stick; returns its cluster or 0 */
static u32 stick_mkdir(u32 pc, const char *name)
{
    u8 n83[11], *e;
    u32 nc, lba;
    u16 off, dt, tm;

    if (!make_83(name, n83)) { note_fail("folder name must be 8.3"); return 0; }
    nc = fat_find_free();
    if (!nc) { note_fail("stick is full"); return 0; }
    fat_set(nc, fat_eocval());
    v_freedelta--; v_hint = nc + 1;
    fat_flush();
    zero_cluster(nc);
    today(&dt, &tm);
    memset(databuf, 0, SECSZ);
    {   u8 dot[11];
        memset(dot, ' ', 11); dot[0] = '.';
        fill_entry(databuf, dot, 0x10, nc, 0, dt, tm);
        dot[1] = '.';
        fill_entry(databuf + 32, dot, 0x10, pc, 0, dt, tm); }
    disk_write(clus2lba(nc), 1, databuf);
    if (!dir_free_slot(pc, &lba, &off)) {
        fat_free_chain(nc); fat_flush();
        note_fail("stick folder is full");
        return 0;
    }
    e = dir_load(lba) + off;
    fill_entry(e, n83, 0x10, nc, 0, dt, tm);
    dir_dirty = 1; dir_flush();
    return nc;
}

static void put_file(const char *path, const char *name, u32 dclus, u16 date, u16 tim)
{
    pg_name("Copying", path);
    if (put_one(path, name, dclus, date, tim)) note_fail(g_lastmsg);
    else pg_files++;
    pg_stats();
}

/* DOS folder -> stick folder dclus (makes "name" there first) */
static void put_dir(const char *path, const char *name, u32 dclus, int depth)
{
    struct find_t f;
    char pat[160], full[160];
    DENT *d = &dpool[depth + 1];
    u32 nc;

    if (dir_find(dclus, name, d)) {
        if (!(d->attr & 0x10)) { note_fail("a stick file has the folder's name"); return; }
        nc = d->clus;
    } else {
        nc = stick_mkdir(dclus, name);
        if (!nc) return;
    }
    if (depth >= MAXDEPTH) { note_fail("folders nested too deep"); return; }
    join(pat, path, "*.*");
    if (_dos_findfirst(pat, _A_NORMAL | _A_RDONLY | _A_HIDDEN | _A_SYSTEM | _A_SUBDIR | _A_ARCH, &f)) return;
    do {
        if (g_cancel) break;
        if (f.name[0] == '.') continue;
        join(full, path, f.name);
        if (f.attrib & _A_SUBDIR) put_dir(full, f.name, nc, depth + 1);
        else put_file(full, f.name, nc, f.wr_date, f.wr_time);
    } while (_dos_findnext(&f) == 0);
}

/* delete everything inside stick folder c */
static void del_stick_tree(u32 c, int depth)
{
    DIT it, save;
    DENT *d;
    u32 k;
    if (depth > MAXDEPTH) { note_fail("folders nested too deep"); return; }
    d = &dpool[depth];
    dit_open(&it, c);
    while (dir_read(&it, d)) {
        if (d->sname[0] == '.') continue;
        if (d->attr & 0x10) {
            if (!clus_ok(d->clus)) { note_fail("bad folder entry on the stick"); return; }
            del_stick_tree(d->clus, depth + 1);
            if (g_fail) return;
        }
        save = it;
        k = d->clus;
        dir_erase(d);
        if (clus_ok(k)) fat_free_chain(k);
        fat_flush();
        it = save;
        if (!(d->attr & 0x10)) pg_files++;
    }
}

static void del_dos(const char *path, int isdir, int depth)
{
    struct find_t f;
    char pat[160], full[160];
    if (isdir) {
        if (depth < MAXDEPTH) {
            join(pat, path, "*.*");
            if (_dos_findfirst(pat, _A_NORMAL | _A_RDONLY | _A_HIDDEN | _A_SYSTEM | _A_SUBDIR | _A_ARCH, &f) == 0) {
                do {
                    if (f.name[0] == '.') continue;
                    join(full, path, f.name);
                    del_dos(full, (f.attrib & _A_SUBDIR) != 0, depth + 1);
                } while (_dos_findnext(&f) == 0);
            }
        }
        if (rmdir(path)) { char m[180]; sprintf(m, "can't remove folder %s", path); note_fail(m); }
    } else {
        _dos_setfileattr(path, _A_NORMAL);
        if (remove(path)) { char m[180]; sprintf(m, "can't delete %s", path); note_fail(m); }
        else pg_files++;
    }
}

/* ------------------------------------------------------------------ */
/*  Commands                                                          */
/* ------------------------------------------------------------------ */

static PANEL *act(void)   { return &g_p[g_act]; }
static PANEL *other(void) { return &g_p[1 - g_act]; }

/* number of items an operation works on (selected ones, or the cursor) */
static int op_count(PANEL *p)
{
    if (p->nsel) return p->nsel;
    if (p->n == 0 || is_dotdot(p->e[p->cur].sname)) return 0;
    return 1;
}

static int op_item(PANEL *p, int i)
{
    if (p->nsel) return p->e[i].sel;
    return i == p->cur;
}

static void op_begin(const char *title)
{
    g_yes = g_yes_cmd;
    g_cancel = 0;
    g_fail = 0; g_failmsg[0] = 0;
    t_bytes = 0;
    g_in_op = 1;
    pg_open(title);
}

static void op_end(const char *what, int wrote_stick)
{
    unsigned long files = pg_files, kbs = kb_per_s();
    char sp[40];
    if (wrote_stick && stick_ok) { dir_flush(); fsinfo_update(); }
    pg_close();
    g_in_op = 0;
    sp[0] = 0;
    if (t_bytes >= 65536UL && kbs)
        sprintf(sp, ", %lu KB at %lu KB/s", t_bytes >> 10, kbs);
    if (g_fail)
        status(A_ERROR, "%s %lu file(s), %d problem(s): %s", what, files, g_fail, g_failmsg);
    else
        status(A_INFO, "%s %lu file(s)%s%s", what, files, sp, g_cancel ? " - stopped" : "");
    if (g_fail) errbox(g_failmsg);
    load_panel(&g_p[0], NULL);
    load_panel(&g_p[1], NULL);
}

static void cmd_copy(void)
{
    PANEL *s = act(), *d = other();
    int n = op_count(s), i;
    char q[200];
    ENT e;

    if (!stick_ok) { errbox("No USB stick connected (press F2 to look again)."); return; }
    if (!n) { status(A_ERROR, "Nothing to copy - select files with Space, Ins or the right button"); return; }
    if (!s->isusb && !stick_writable()) return;
    sprintf(q, "Copy %d item%s\nfrom %s%s\n  to %s%s", n, n == 1 ? "" : "s",
            s->isusb ? "USB:" : "", s->path, d->isusb ? "USB:" : "", d->path);
    if (dialog("Copy", q, "Copy|Cancel", A_DLG) != 0) return;

    op_begin(s->isusb ? "Copying USB -> DOS" : "Copying DOS -> USB");
    for (i = 0; i < s->n && !g_cancel; i++) {
        if (!op_item(s, i)) continue;
        _fmemcpy(&e, &s->e[i], sizeof(ENT));
        if (is_dotdot(e.sname)) continue;
        if (s->isusb) {
            if (!dir_find(g_sdc, e.sname, &dpool[0])) { note_fail("file vanished from the stick"); continue; }
            if (dpool[0].attr & 0x10) get_dir(&dpool[0], d->path, 0);
            else get_file(&dpool[0], d->path);
        } else {
            char full[160];
            join(full, s->path, e.sname);
            if (e.attr & 0x10) put_dir(full, e.sname, g_sdc, 0);
            else put_file(full, e.sname, g_sdc, e.date, e.time);
        }
    }
    op_end("Copied", !s->isusb);
}

static void cmd_delete(void)
{
    PANEL *p = act();
    int n = op_count(p), i, dirs = 0;
    char q[220];
    ENT e;

    if (p->isusb && !stick_ok) return;
    if (!n) { status(A_ERROR, "Nothing to delete"); return; }
    if (p->isusb && !stick_writable()) return;
    for (i = 0; i < p->n; i++) if (op_item(p, i) && (p->e[i].attr & 0x10)) dirs++;
    if (n == 1) {
        _fmemcpy(&e, &p->e[p->cur], sizeof(ENT));
        for (i = 0; i < p->n; i++) if (op_item(p, i)) { _fmemcpy(&e, &p->e[i], sizeof(ENT)); break; }
        sprintf(q, "Delete %s %s\nfrom %s%s ?", (e.attr & 0x10) ? "folder" : "file",
                e.lname[0] ? e.lname : e.sname, p->isusb ? "USB:" : "", p->path);
    } else
        sprintf(q, "Delete %d items from %s%s ?", n, p->isusb ? "USB:" : "", p->path);
    if (dirs) strcat(q, "\n\nFolders are deleted with everything in them!");
    if (dialog("Delete", q, "Delete|Cancel", A_DLGERR) != 0) return;

    op_begin("Deleting");
    for (i = 0; i < p->n && !g_cancel && !g_fail; i++) {
        if (!op_item(p, i)) continue;
        _fmemcpy(&e, &p->e[i], sizeof(ENT));
        if (is_dotdot(e.sname)) continue;
        pg_name("Deleting", e.lname[0] ? e.lname : e.sname);
        if (p->isusb) {
            DENT *d = &dpool[0];
            u32 k;
            if (!dir_find(g_sdc, e.sname, d)) continue;
            if (d->attr & 0x10) {
                if (!clus_ok(d->clus)) { note_fail("bad folder entry on the stick"); break; }
                del_stick_tree(d->clus, 1);
                if (g_fail) break;
            }
            k = d->clus;
            dir_erase(d);
            if (clus_ok(k)) fat_free_chain(k);
            fat_flush();
            if (!(d->attr & 0x10)) pg_files++;
        } else {
            char full[160];
            join(full, p->path, e.sname);
            del_dos(full, (e.attr & 0x10) != 0, 0);
        }
        pg_stats();
    }
    op_end("Deleted", p->isusb);
}

static void cmd_mkdir(void)
{
    PANEL *p = act();
    char name[64], full[160];
    u8 n83[11];

    if (p->isusb && !stick_ok) return;
    name[0] = 0;
    if (!input_box("New folder", p->isusb ? "Folder name on the stick (8.3, like PHOTOS):"
                                          : "Folder name (8.3, like PHOTOS):", name, 12)) return;
    if (!name[0]) return;
    if (!make_83(name, n83)) { errbox("Use an 8.3 name: up to 8 letters, optional .EXT"); return; }
    strupr(name);
    if (p->isusb) {
        if (!stick_writable()) return;
        if (dir_find(g_sdc, name, &dpool[0])) { errbox("That name already exists on the stick."); return; }
        g_fail = 0;
        if (!stick_mkdir(g_sdc, name)) { errbox(g_failmsg); return; }
        fsinfo_update();
    } else {
        join(full, p->path, name);
        if (mkdir(full)) { errbox("Couldn't make that folder (exists, or disk full?)"); return; }
    }
    load_panel(p, name);
    status(A_INFO, "Folder %s made", name);
}

static void enter_dir(PANEL *p)
{
    ENT e;
    char gone[80], keep[13];
    if (p->n == 0) return;
    _fmemcpy(&e, &p->e[p->cur], sizeof(ENT));
    if (!(e.attr & 0x10)) return;
    keep[0] = 0;
    if (is_dotdot(e.sname)) {
        path_up(p->path, gone);
        if (p->isusb) {
            g_sdc = e.clus;
            if (v_type == 32 && g_sdc == v_rootclus) g_sdc = 0;
            /* find the short name of the folder we came out of */
            {   DIT it; DENT *d = &dpool[0];
                dit_open(&it, g_sdc);
                while (dir_read(&it, d))
                    if (ci_eq(d->lname, gone) || ci_eq(d->sname, gone)) { strcpy(keep, d->sname); break; }
            }
        } else { strncpy(keep, gone, 12); keep[12] = 0; }
    } else {
        char np[160];
        join(np, p->path, (p->isusb && e.lname[0]) ? e.lname : e.sname);
        if (!p->isusb && strlen(np) > 66) { status(A_ERROR, "Path too long for DOS"); return; }
        if (strlen(np) > 120) np[120] = 0;
        strcpy(p->path, np);
        if (p->isusb) g_sdc = e.clus;
    }
    p->top = 0;
    load_panel(p, keep[0] ? keep : "..");
}

static void go_up(PANEL *p)
{
    int i;
    for (i = 0; i < p->n; i++)
        if (is_dotdot(p->e[i].sname)) { p->cur = i; enter_dir(p); return; }
}

static void toggle_sel(PANEL *p, int i)
{
    ENT far *e;
    if (i < 0 || i >= p->n) return;
    e = &p->e[i];
    if (is_dotdot(e->sname)) return;
    e->sel = (u8)!e->sel;
    if (e->sel) { p->nsel++; p->selbytes += e->size; }
    else { p->nsel--; p->selbytes -= e->size; }
}

static void select_all(PANEL *p, int mode)     /* 1 = all files, 0 = none, 2 = invert */
{
    int i;
    for (i = 0; i < p->n; i++) {
        ENT far *e = &p->e[i];
        int want;
        if (is_dotdot(e->sname)) continue;
        if (mode == 2) want = !e->sel;
        else want = mode && !(e->attr & 0x10);
        if (want != e->sel) toggle_sel(p, i);
    }
}

static int drive_ok(int d)      /* d: 1 = A: */
{
    union REGS r;
    u16 eq = *(u16 far *)0x00400010L;
    int floppies = (eq & 1) ? ((eq >> 6) & 3) + 1 : 0;
    if (d <= 2 && d > floppies) return 0;       /* no phantom B: prompt */
    r.x.ax = 0x4408; r.h.bl = (u8)d;
    intdos(&r, &r);
    if (r.x.cflag && r.x.ax == 0x0F) return 0;
    return 1;
}

static void cmd_drive(void)
{
    char btns[80], letters[27], q[40];
    int n = 0, d, k;
    PANEL *p = &g_p[0];
    btns[0] = 0;
    for (d = 1; d <= 26 && n < 12; d++)
        if (drive_ok(d)) {
            letters[n++] = (char)('A' + d - 1);
            sprintf(q, "%s%c:", n > 1 ? "|" : "", 'A' + d - 1);
            strcat(btns, q);
        }
    strcat(btns, "|Cancel");
    k = dialog("DOS drive", "Show which drive in the left panel?", btns, A_DLG);
    if (k >= n) return;
    p->path[0] = letters[k]; p->path[1] = ':'; p->path[2] = '\\'; p->path[3] = 0;
    {   /* start in that drive's current folder */
        union REGS r; struct SREGS s; char cwd[70];
        segread(&s);
        r.h.ah = 0x47; r.h.dl = (u8)(letters[k] - 'A' + 1);
        r.x.si = (unsigned)cwd;
        intdosx(&r, &r, &s);
        if (!r.x.cflag && cwd[0]) strcat(p->path, cwd);
    }
    g_act = 0;
    p->top = p->cur = 0;
    load_panel(p, "");
}

static void cmd_stickinfo(void)
{
    char t[600], where[50];
    unsigned long kb, mb = v_clusters * v_spc / 2048UL;
    char f[20];
    if (!stick_ok) { msgbox("USB stick", stick_msg[0] ? stick_msg : "No USB stick connected."); return; }
    kb = stick_free_kb();
    if (kb != 0xFFFFFFFFUL) fmt_size_kb(f, kb); else strcpy(f, "unknown");
    if (g_usb) { strncpy(where, usb_where, 49); where[49] = 0; }
    else sprintf(where, "BIOS drive %02Xh", g_drive);
    sprintf(t, "Stick:     %s\n"
               "Where:     %s\n"
               "Volume:    \"%s\"  serial %04lX-%04lX\n"
               "Type:      FAT%d, partition at sector %lu\n"
               "Size:      about %lu MB, %lu-byte clusters\n"
               "Free:      %s",
            g_usb ? usb_name : "BIOS disk",
            where,
            v_label, UL(v_serial >> 16), UL(v_serial & 0xFFFF),
            v_type, UL(v_start), mb, UL(v_clusbytes), f);
    msgbox("USB stick", t);
}

static void cmd_help(void)
{
    msgbox("USBXGUI " GUIVER " help",
        "MOUSE                          KEYBOARD\n"
        "Left click    pick a file      Arrows/PgUp/PgDn  move\n"
        "Double click  open a folder    Tab               other panel\n"
        "Right click   select/unselect  Enter / BkSp      open / go up\n"
        "Arrows in the frame  page      Space or Ins      select\n"
        "Click the left title  drive    + / - / *  all / none / invert\n"
        "Bottom bar    F-key commands   F1-F10            commands\n"
        "\n"
        "F5 copies the selected files (or the one under the bar)\n"
        "from this panel to the other one. Folders are copied with\n"
        "everything in them. Stick files get 8.3 names on DOS.\n"
        "F2 rescans: use it after swapping USB sticks.");
}

static int confirm_quit(void)
{
    return dialog("Quit", "Leave USBXGUI?", "Yes|No", A_DLG) == 0;
}

/* ------------------------------------------------------------------ */
/*  Main                                                              */
/* ------------------------------------------------------------------ */

static void video_text(void)
{
    union REGS r;
    r.x.ax = 0x0003; int86(0x10, &r, &r);       /* 80x25 colour text */
    r.x.ax = 0x1003; r.h.bl = 0; int86(0x10, &r, &r);    /* bright backgrounds, no blink */
    r.h.ah = 0x01; r.x.cx = 0x2000; int86(0x10, &r, &r);  /* hide text cursor */
}

static void video_restore(void)
{
    union REGS r;
    r.x.ax = 0x0003; int86(0x10, &r, &r);
    if (m_present) { r.x.ax = 0; m_call(&r); }   /* driver forgets our screen */
}

static void after_error(void)
{
    /* a disk error (gui_die) jumped here from deep inside an operation */
    while (m_hidden > 0) m_show();
    pg_on = 0;
    g_nsave = 0;                     /* whole screen is redrawn below */
    fcloseall();
    g_in_op = 0;
    stick_drop();
    sprintf(stick_msg, "USB error: %.60s", g_errmsg);
    draw_all();
    errbox("The USB stick stopped answering or gave a disk error.\n"
           "Check it is plugged in, then press F2 to reconnect.\n"
           "If files were being written, run fsck.vfat on Linux.");
    status(A_ERROR, "USB error: %s", g_errmsg);
}

static void usage_gui(void)
{
    puts("USBXGUI " GUIVER " - mouse file manager for a USB stick under DOS\n\n"
         "  USBXGUI [/U] [/2] [/C:n] [/D:81] [/P:n] [/Y]\n\n"
         "  /U  use the USB controller directly   /C:n  n-th USB 1.1 controller\n"
         "  /2  USB 2.0 speed                     /D:81 use BIOS drive 81h\n"
         "  /P:n  partition n                     /Y    don't ask before overwriting\n");
}

int main(int argc, char **argv)
{
    int i, k;
    EV ev;
    char cwd[80];

    for (i = 1; i < argc; i++) {
        char *a = argv[i];
        if (a[0] == '/' && a[1] && (a[2] == ':' || a[2] == 0)) {
            switch (toupper((u8)a[1])) {
            case 'D': g_drive_cmd = (int)strtol(a + 3, NULL, 16); break;
            case 'P': g_part = atoi(a + 3); break;
            case 'Y': g_yes_cmd = 1; break;
            case 'U': g_force_usb = 1; break;
            case '2': g_usbfl = 3; g_force_usb = 1; break;
            case 'C': g_ctl = atoi(a + 3); g_force_usb = 1; break;
            default: usage_gui(); return 0;
            }
        } else { usage_gui(); return 0; }
    }

    for (i = 0; i < NSAVE; i++) {
        g_save[i] = (unsigned short far *)_fmalloc(SCRW * SCRH * 2);
        if (!g_save[i]) { puts("USBXGUI: not enough memory"); return 2; }
    }
    for (k = 0; k < 2; k++) {
        memset(&g_p[k], 0, sizeof(PANEL));
        g_p[k].e = (ENT far *)_fmalloc(sizeof(ENT) * MAXENT);
        if (!g_p[k].e) { puts("USBXGUI: not enough memory"); return 2; }
        g_p[k].x = k * 40;
        g_p[k].isusb = k;
    }
    if (!getcwd(cwd, sizeof(cwd))) strcpy(cwd, "C:\\");
    strncpy(g_p[0].path, cwd, 120);
    strcpy(g_p[1].path, "\\");

    _harderr(crit_handler);
    video_text();
    m_present = m_init();
    if (m_present) { union REGS r; r.x.ax = 1; m_call(&r); }
    status(A_STATUS, m_present ? "Looking for the USB stick..." : "Looking for the USB stick... (no mouse driver - keyboard only)");
    draw_frame();

    if (setjmp(g_jmp)) {
        after_error();
        load_panel(&g_p[0], NULL);
        g_p[1].n = 0;
    } else {
        if (stick_attach() == 0) {
            status(A_INFO, "%s%s", m_present ? "" : "No mouse driver - keyboard only.  ",
                   "F5 copies between the panels.  F1 = help");
            g_act = 1;
        } else
            status(A_ERROR, "No USB stick: %s", stick_msg);
        load_panel(&g_p[0], NULL);
        load_panel(&g_p[1], NULL);
    }

    for (;;) {
        PANEL *p;
        int key = 0;

        draw_all();
        get_event(&ev);
        p = act();

        if (ev.type == EV_LEFT || ev.type == EV_RIGHT) {
            int k2 = ev.x / 40;
            PANEL *q = &g_p[k2];
            if (ev.y == 24) { key = K_F1 + ev.x / 8; if (ev.type == EV_RIGHT) key = 0; }
            else if (ev.y >= 1 && ev.y <= 22) {
                g_act = k2;
                if (q->isusb && !stick_ok) { if (ev.y > 1 && ev.y < 22) key = K_F2; }
                else if (ev.y == 1) {
                    if (ev.x % 40 == 38) key = K_PGUP;
                    else if (!q->isusb) key = K_F3;
                } else if (ev.y == 22) key = K_PGDN;
                else if (ev.y >= LTOP && ev.y < LTOP + LROWS && ev.x % 40 >= 1 && ev.x % 40 <= 38) {
                    int idx = q->top + ev.y - LTOP;
                    if (idx < q->n) {
                        q->cur = idx;
                        if (ev.type == EV_RIGHT) toggle_sel(q, idx);
                        else if (ev.dbl) enter_dir(q);
                    }
                }
                p = act();
            }
            if (!key) continue;
        } else key = ev.key;

        switch (key) {
        case K_UP:   p->cur--; fix_view(p); break;
        case K_DOWN: p->cur++; fix_view(p); break;
        case K_PGUP: p->cur -= LROWS - 1; p->top -= LROWS - 1; fix_view(p); break;
        case K_PGDN: p->cur += LROWS - 1; p->top += LROWS - 1; fix_view(p); break;
        case K_HOME: p->cur = 0; fix_view(p); break;
        case K_END:  p->cur = p->n - 1; fix_view(p); break;
        case 9: case K_LEFT: case K_RIGHT:
            if (key == K_LEFT) g_act = 0; else if (key == K_RIGHT) g_act = 1; else g_act = 1 - g_act;
            break;
        case 13: enter_dir(p); break;
        case 8:  go_up(p); break;
        case ' ': case K_INS: toggle_sel(p, p->cur); p->cur++; fix_view(p); break;
        case '+': select_all(p, 1); break;
        case '-': select_all(p, 0); break;
        case '*': select_all(p, 2); break;
        case K_F1: cmd_help(); break;
        case K_F2: case 18:            /* F2 or Ctrl-R */
            status(A_STATUS, "Looking for the USB stick...");
            if (stick_attach() == 0) { status(A_INFO, "USB stick ready"); }
            else status(A_ERROR, "No USB stick: %s", stick_msg);
            load_panel(&g_p[0], NULL);
            load_panel(&g_p[1], "");
            break;
        case K_F3: cmd_drive(); break;
        case K_F4: cmd_stickinfo(); break;
        case K_F5: cmd_copy(); break;
        case K_F6: select_all(p, p->nsel ? 0 : 1); break;
        case K_F7: cmd_mkdir(); break;
        case K_F8: case K_DEL: cmd_delete(); break;
        case K_F10: case K_ALTX: case 27:
            if (confirm_quit()) goto quit;
            break;
        }
    }
quit:
    if (stick_ok) { dir_flush(); fat_flush(); }
    stick_drop();
    video_restore();
    puts("USBXGUI ended.");
    return 0;
}

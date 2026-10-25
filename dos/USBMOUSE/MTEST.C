/* MTEST.C - INT 33h mouse test: shows position/buttons, logs changes.
   MTEST [seconds]   (default 20). Press a key to stop early. */
#include <stdio.h>
#include <stdlib.h>
#include <dos.h>
#include <conio.h>

/* event handler: counts calls in the BIOS "intra-application" area 0040:00F0 */
void far mhandler(void)
{
    _asm {
        push es
        push bx
        mov  bx, 40h
        mov  es, bx
        inc  word ptr es:[0F0h]
        mov  es:[0F2h], ax
        mov  es:[0F4h], cx
        pop  bx
        pop  es
    }
}

static unsigned long ticks(void) { return *(unsigned long volatile far *)0x0040006CL; }

int main(int argc, char **argv)
{
    union REGS r;
    unsigned long t0, now, secs = argc > 1 ? atol(argv[1]) : 20;
    int lx = -1, ly = -1, lb = -1, changes = 0;
    FILE *f = fopen("MTEST.TXT", "w");

    r.x.ax = 0; int86(0x33, &r, &r);
    printf("reset: AX=%04X buttons=%u\n", r.x.ax, r.x.bx);
    if (f) fprintf(f, "reset: AX=%04X buttons=%u\n", r.x.ax, r.x.bx);
    if (r.x.ax != 0xFFFF) { printf("no mouse driver\n"); if (f) fclose(f); return 1; }
    r.x.ax = 0x24; int86(0x33, &r, &r);
    if (f) fprintf(f, "version %X.%02X type %u\n", r.h.bh, r.h.bl, r.h.ch);
    r.x.ax = 0x26; int86(0x33, &r, &r);
    if (f) fprintf(f, "max x=%u y=%u\n", r.x.cx, r.x.dx);
    if (argc > 2) {                                  /* MTEST n G : test in mode 13h */
        unsigned char far *v = (unsigned char far *)0xA0000000L;
        unsigned i;
        r.x.ax = 0x13; int86(0x10, &r, &r);
        for (i = 0; i < 64000u; i++) v[i] = (unsigned char)(32 + (i % 320) / 10);
        r.x.ax = 0; int86(0x33, &r, &r);
    }
    {   struct SREGS s; void (far *h)(void) = mhandler;
        *(unsigned far *)0x004000F0L = 0;
        segread(&s);
        r.x.ax = 0x0C; r.x.cx = 0x7F; r.x.dx = FP_OFF(h); s.es = FP_SEG(h);
        int86x(0x33, &r, &r, &s);
    }
    r.x.ax = 1; int86(0x33, &r, &r);                 /* show cursor */

    t0 = ticks();
    while ((now = ticks()) - t0 < secs * 18UL) {
        r.x.ax = 3; int86(0x33, &r, &r);
        if ((int)r.x.cx != lx || (int)r.x.dx != ly || (int)r.x.bx != lb) {
            lx = r.x.cx; ly = r.x.dx; lb = r.x.bx;
            changes++;
            printf("\r t=%5.1fs  x=%4d y=%4d  buttons=%d   ", (now - t0) / 18.2, lx, ly, lb);
            if (f) fprintf(f, "t=%5.1f x=%d y=%d b=%d\n", (now - t0) / 18.2, lx, ly, lb);
        }
        if (kbhit()) { getch(); break; }
    }
    r.x.ax = 5; r.x.bx = 0; int86(0x33, &r, &r);
    if (f) fprintf(f, "left presses: %u (last at %u,%u)\n", r.x.bx, r.x.cx, r.x.dx);
    r.x.ax = 6; r.x.bx = 0; int86(0x33, &r, &r);
    if (f) fprintf(f, "left releases: %u\n", r.x.bx);
    r.x.ax = 0xFF01; int86(0x33, &r, &r);
    if (f && r.x.ax == 0x5553) fprintf(f, "USBMOUSE: %u reports, %u errors, mouse %s\n",
                                       r.x.bx, r.x.cx, r.x.dx ? "connected" : "gone");
    if (f) fprintf(f, "%d changes\n", changes);
    if (f) fprintf(f, "event handler called %u times, last mask %02Xh x=%u\n",
                   *(unsigned far *)0x004000F0L, *(unsigned far *)0x004000F2L, *(unsigned far *)0x004000F4L);
    r.x.ax = 0x0C; r.x.cx = 0; int86(0x33, &r, &r);   /* remove handler */
    r.x.ax = 2; int86(0x33, &r, &r);
    printf("\n%d changes logged to MTEST.TXT\n", changes);
    if (f) fclose(f);
    return 0;
}

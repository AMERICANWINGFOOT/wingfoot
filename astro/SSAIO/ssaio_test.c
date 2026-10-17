/*
 * ssaio_test.c - plain C check that the QHY SDK can open the
 * StarShoot All-in-One and grab one frame. Writes ssaio_test.pgm.
 * Usage: ./ssaio_test [exposure_ms] [gain]   (defaults 50 ms, gain 20)
 * Run this before the QB64 test: if it fails, the problem is the SDK
 * or the camera, not the QB64 side.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include "libssaio.h"

int main(int argc, char **argv)
{
    double expo = (argc > 1) ? atof(argv[1]) : 50.0;   /* ms */
    double gain = (argc > 2) ? atof(argv[2]) : 20.0;
    int n, rc, w, h, need, got;
    char model[64];
    unsigned char *buf;
    FILE *f;

    n = ssaio_init();
    printf("Cameras found: %d\n", n);
    if (n < 1) { ssaio_close(); return 1; }

    rc = ssaio_open(0);
    if (rc != 0) { printf("Open failed, code %d\n", rc); ssaio_close(); return 1; }

    ssaio_model((intptr_t)model, sizeof(model));
    w = ssaio_width();
    h = ssaio_height();
    printf("Model: %s\n", model);
    printf("Size : %d x %d, pixel %.2f um, colour id %d\n",
           w, h, ssaio_pixel_um(), ssaio_is_color());

    printf("Exposure %.3f ms, gain %.1f\n", expo, gain);
    ssaio_set_exposure_ms(expo);
    ssaio_set_gain(gain);

    /* room for 16-bit too, in case the SDK ignores 8-bit mode */
    need = w * h * 2;
    buf = (unsigned char *)malloc(need);
    if (!buf) { ssaio_close(); return 1; }

    got = ssaio_grab((intptr_t)buf, need);
    if (got < 0) { printf("Grab failed, code %d\n", got); free(buf); ssaio_close(); return 1; }
    printf("Grabbed %d bytes (%d bytes/pixel)\n", got, got / (w * h));
    {
        int i, bp = got / (w * h), mn = 255, mx = 0, v;
        double sum = 0;
        for (i = 0; i < w * h; i++) {
            v = buf[i * bp + bp - 1];
            if (v < mn) mn = v;
            if (v > mx) mx = v;
            sum += v;
        }
        printf("Pixel min %d  max %d  mean %.1f\n", mn, mx, sum / (w * h));
    }

    f = fopen("ssaio_test.pgm", "wb");
    if (f) {
        fprintf(f, "P5\n%d %d\n255\n", w, h);
        if (got / (w * h) == 1) {
            fwrite(buf, 1, (size_t)w * h, f);
        } else {
            int i;
            for (i = 0; i < w * h; i++) fputc(buf[i * 2 + 1], f);  /* high byte */
        }
        fclose(f);
        printf("Saved ssaio_test.pgm\n");
    }

    free(buf);
    ssaio_close();
    return 0;
}

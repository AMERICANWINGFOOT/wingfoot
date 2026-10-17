/*
 * ssg3_shim.c - flat C wrapper around orion_ssg3.c for QB64-PE
 *
 * QB64 never sees struct orion_ssg3; it just calls these functions.
 * One camera open at a time.
 * v2: ssg3_drain() - the G3 has no abort command, so after a stopped
 *     exposure its image data is read and thrown away.
 *
 * Build:  ./build_g3.sh   (makes libssg3.so)
 */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include "orion_ssg3.h"

#define SSG3_MAX 8

static struct orion_ssg3_info infos[SSG3_MAX];
static int ninfo = 0;
static struct orion_ssg3 cam;
static int isOpen = 0;
static char lastErr[256] = "";

static void set_err(const char *what, int rc)
{
    snprintf(lastErr, sizeof(lastErr), "%s failed: %d (%s)", what, rc,
             rc < 0 ? strerror(-rc) : "?");
}

int ssg3_version(void) { return 2; }

/* Copy the last error text into buf; returns its length */
int ssg3_last_error(char *buf, int blen)
{
    if (!buf || blen < 1) return 0;
    strncpy(buf, lastErr, blen - 1);
    buf[blen - 1] = 0;
    return (int) strlen(buf);
}

/* Scan USB for G3 cameras; returns count (0 = none, <0 = libusb error) */
int ssg3_count(void)
{
    int i, rc;
    for (i = 0; i < ninfo; i++) {
        if (infos[i].dev) libusb_unref_device(infos[i].dev);
        infos[i].dev = NULL;
    }
    ninfo = 0;
    rc = orion_ssg3_camera_info(infos, SSG3_MAX);
    if (rc < 0) { set_err("camera scan", rc); return rc; }
    ninfo = rc;
    return ninfo;
}

/* USB product id of camera idx (0x0502 / 0x0501), 0 if bad index */
int ssg3_usb_pid(int idx)
{
    if (idx < 0 || idx >= ninfo) return 0;
    return infos[idx].model->pid;
}

/* Driver's own guess at color (1) / mono (0). Not reliable - the app
   should let the user pick. */
int ssg3_driver_says_color(int idx)
{
    if (idx < 0 || idx >= ninfo) return -1;
    return infos[idx].model->color ? 1 : 0;
}

int ssg3_open(int idx)
{
    int rc;
    if (isOpen) return 0;
    if (idx < 0 || idx >= ninfo) { strcpy(lastErr, "bad camera index - call ssg3_count first"); return -EINVAL; }
    memset(&cam, 0, sizeof(cam));
    rc = orion_ssg3_open(&cam, &infos[idx]);
    if (rc) { set_err("open", rc); return rc; }
    isOpen = 1;
    return 0;
}

void ssg3_close(void)
{
    if (isOpen) orion_ssg3_close(&cam);
    isOpen = 0;
}

int ssg3_width(void)  { return isOpen ? orion_ssg3_get_image_width(&cam)  : 0; }
int ssg3_height(void) { return isOpen ? orion_ssg3_get_image_height(&cam) : 0; }

/* Bytes the download needs (16-bit pixels) */
int ssg3_frame_bytes(void)
{
    return isOpen ? (int) cam.x_count * (int) cam.y_count * 2 : 0;
}

int ssg3_set_gain(int g)
{
    int rc;
    if (!isOpen) return -ENODEV;
    if (g < 0) g = 0;
    if (g > 255) g = 255;
    rc = orion_ssg3_set_gain(&cam, (uint8_t) g);
    if (rc) set_err("set gain", rc);
    return rc;
}

int ssg3_set_offset(int o)
{
    int rc;
    if (!isOpen) return -ENODEV;
    if (o < 0) o = 0;
    if (o > 255) o = 255;
    rc = orion_ssg3_set_offset(&cam, (uint8_t) o);
    if (rc) set_err("set offset", rc);
    return rc;
}

int ssg3_start_exposure(int ms)
{
    int rc;
    if (!isOpen) return -ENODEV;
    if (ms < 1) ms = 1;
    rc = orion_ssg3_start_exposure(&cam, (uint32_t) ms);
    if (rc) set_err("start exposure", rc);
    return rc;
}

/* 1 when the camera should be ready to send the frame */
int ssg3_exposure_done(void)
{
    return isOpen ? orion_ssg3_exposure_done(&cam) : 1;
}

/* Read the frame into buf (must hold ssg3_frame_bytes()). Blocks during
   readout. Pixels come back de-interlaced, host-order 16-bit. */
int ssg3_download(void *buf, int blen)
{
    int rc, need;
    if (!isOpen) return -ENODEV;
    need = ssg3_frame_bytes();
    if (!buf || blen < need) { strcpy(lastErr, "download buffer too small"); return -ENOSPC; }
    /* orion_ssg3_image_download's size check is inverted (it rejects
       buffers LARGER than the frame), so always pass exactly 'need'. */
    rc = orion_ssg3_image_download(&cam, (uint8_t *) buf, need);
    if (rc) set_err("download", rc);
    return rc;
}

/* Sensor temperature in tenths of a degree C */
int ssg3_temp_x10(int *tx10)
{
    float t = 0;
    int rc;
    if (!isOpen) return -ENODEV;
    rc = orion_ssg3_get_temperature(&cam, &t);
    if (rc) { set_err("read temperature", rc); return rc; }
    if (tx10) *tx10 = (int) (t * 10.0f + (t < 0 ? -0.5f : 0.5f));
    return 0;
}

/* on=0 turns the cooler off; otherwise cool to tx10 tenths of a degree */
int ssg3_cooler(int on, int tx10)
{
    int rc;
    if (!isOpen) return -ENODEV;
    if (on) rc = orion_ssg3_set_temperature(&cam, tx10 / 10.0f);
    else    rc = orion_ssg3_cooling_off(&cam);
    if (rc) set_err("cooler", rc);
    return rc;
}

int ssg3_cooler_power(int *pct)
{
    float p = 0;
    int rc;
    if (!isOpen) return -ENODEV;
    rc = orion_ssg3_get_cooling_power(&cam, &p);
    if (rc) { set_err("cooler power", rc); return rc; }
    if (pct) *pct = (int) p;
    return 0;
}

/* Read and discard image data still coming from the camera (after an
   exposure that was stopped). Returns bytes thrown away. Stops at the
   first read that times out (timeoutMs) or after 8 MB. */
int ssg3_drain(int timeoutMs)
{
    static unsigned char junk[16384];
    int got, rc, total = 0;
    if (!isOpen) return 0;
    if (timeoutMs < 50) timeoutMs = 50;
    for (;;) {
        got = 0;
        rc = libusb_bulk_transfer(cam.devh, 0x82, junk, sizeof junk, &got, timeoutMs);
        total += got;
        if (rc || total > 8 * 1024 * 1024) break;
    }
    return total;
}

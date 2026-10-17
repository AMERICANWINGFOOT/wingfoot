// g3d_common.h - GPU3D state and the functions every back end exports the same way
//
// A back end (g3d.cu for CUDA, g3d_vk.cpp for Vulkan) includes this file, then
// adds its own g3_init, g3_shutdown, g3_set_texture, g3_draw and device queries.
#ifndef G3D_COMMON_H
#define G3D_COMMON_H

#include "g3d_math.h"

#ifdef _WIN32
  #define WIN32_LEAN_AND_MEAN
  #include <windows.h>
  #define G3_API __declspec(dllexport)
#else
  #define G3_API __attribute__((visibility("default")))
#endif

// ---------------------------------------------------------------- library state

static Obj g_obj[G3_MAXOBJ];            // shapes as queued (this frame's list)
static int g_nobj = 0;
static View g_view;
static uint32_t g_tex[G3_MAXTEX * G3_TEX * G3_TEX];
static float g_gpuMs = 0, g_hostMs = 0;
static char g_err[512] = "";

static double now_ms(void)
{
#ifdef _WIN32
    LARGE_INTEGER f, c;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1000.0 / (double)f.QuadPart;
#else
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000.0 + t.tv_nsec / 1.0e6;
#endif
}

static void view_defaults(int W, int H)
{
    g_view.W = W; g_view.H = H;
    g_view.f = (float)W;
    g_view.vx = W * 0.5f; g_view.vy = H * 0.5f;
    g_view.L = vnorm(v3(-0.45f, -0.65f, -0.6f));     // from the upper left, toward the viewer
    g_view.amb = 0.28f;
    g_view.lw = 1.5f;
    g_view.aa = 4;
    g_view.fill = 0; g_view.bg = 0xFF000000u;
    g_view.fogNear = 0; g_view.fogFar = 0; g_view.fogColor = 0xFF000000u;
}

// Shapes that can be seen, each with its screen rectangle. Returns how many.
static int cull_list(const View &v, Obj *out)
{
    int n = 0;
    for (int i = 0; i < g_nobj; i++) {
        Obj o = g_obj[i];
        if (obj_rect(o, v)) out[n++] = o;
    }
    return n;
}

// Put a finished frame into the QB64 image. In fill mode it is a plain copy;
// otherwise alpha says how much of each pixel the shapes cover.
static void composite(uint32_t *pixels, const uint32_t *src, size_t npix, int fill)
{
    if (fill) {
        memcpy(pixels, src, npix * 4);
        return;
    }
    for (size_t i = 0; i < npix; i++) {
        uint32_t s = src[i];
        uint32_t a = s >> 24;
        if (a == 0) continue;
        if (a == 255) { pixels[i] = s; continue; }
        uint32_t p = pixels[i], ia = 255 - a;
        uint32_t r = (((s >> 16) & 255) * a + ((p >> 16) & 255) * ia + 127) / 255;
        uint32_t g = (((s >> 8) & 255) * a + ((p >> 8) & 255) * ia + 127) / 255;
        uint32_t b = ((s & 255) * a + (p & 255) * ia + 127) / 255;
        pixels[i] = (p & 0xFF000000u) | (r << 16) | (g << 8) | b;
    }
}

// store a texture on the host side; the back end then sends it to its GPUs
static uint32_t *tex_store(int id, const uint32_t *pixels)
{
    if (id < 1 || id >= G3_MAXTEX || !pixels) return NULL;
    uint32_t *dst = g_tex + (size_t)id * G3_TEX * G3_TEX;
    memcpy(dst, pixels, G3_TEX * G3_TEX * 4);
    return dst;
}

extern "C" {

// focal = perspective strength in pixels (default: screen width); <= 0 = no perspective.
// (vx, vy) = the vanishing point, normally the screen centre.
G3_API void g3_view(float focal, float vx, float vy)
{
    g_view.f = focal;
    g_view.vx = vx;
    g_view.vy = vy;
}

// direction toward the light, in screen axes (x right, y down, z into the screen)
G3_API void g3_light(float lx, float ly, float lz, float ambient)
{
    g_view.L = vnorm(v3(lx, ly, lz));
    g_view.amb = clamp01(ambient);
}

// depth fog from z = nearZ (none) to z = farZ (all fog); farZ <= nearZ = off
G3_API void g3_fog(float nearZ, float farZ, uint32_t color)
{
    g_view.fogNear = nearZ;
    g_view.fogFar = farZ;
    g_view.fogColor = color;
}

// aa = samples per pixel (1, 4, 9 or 16); lineWidth = wire and outline width in pixels
G3_API void g3_quality(int aa, float lineWidth)
{
    g_view.aa = (aa >= 16) ? 16 : (aa >= 9) ? 9 : (aa >= 4) ? 4 : 1;
    g_view.lw = fminf(fmaxf(lineWidth, 0.25f), 16.0f);
}

// empty the shape list
G3_API void g3_begin(void)
{
    g_nobj = 0;
}

// queue one shape; returns its number (0, 1, 2 ...) or -1 when the list is full
G3_API int g3_add(int shape, float x, float y, float z, float w, float h, float d,
                  float ax, float ay, float az, uint32_t color, int tex, int flags)
{
    if (g_nobj >= G3_MAXOBJ) return -1;
    build_obj(g_obj[g_nobj], shape, x, y, z, w, h, d, ax, ay, az, color, tex, flags);
    return g_nobj++;
}

G3_API int g3_count(void) { return g_nobj; }

// The shape seen at screen pixel (sx, sy), or -1 for none (worked out on the CPU)
G3_API int g3_pick(float sx, float sy)
{
    V3 O, D;
    float best = 1e30f, t;
    int found = -1, side;
    make_ray(g_view, sx, sy, O, D);
    for (int i = 0; i < g_nobj; i++) {
        if (obj_hit(g_obj[i], g_view, O, D, t, side) && t < best) { best = t; found = i; }
    }
    return found;
}

G3_API void g3_stats(float *gpuMs, float *hostMs)
{
    *gpuMs = g_gpuMs;
    *hostMs = g_hostMs;
}

G3_API void g3_last_error(char *msg, int msglen)
{
    if (!msg || msglen <= 0) return;
    strncpy(msg, g_err, (size_t)msglen - 1);
    msg[msglen - 1] = 0;
}

} // extern "C"

#endif // G3D_COMMON_H

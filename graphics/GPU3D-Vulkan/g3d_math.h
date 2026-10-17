// g3d_math.h - GPU3D shape math, shared by every back end (CUDA, Vulkan host side, CPU)
//
// Everything here works in screen pixels: x right, y down, z into the screen.
// A shape is a unit box / sphere / cylinder / cone / pyramid / diamond that is
// scaled by its half sizes, rotated, and moved to its centre. Each pixel's ray
// is turned into the shape's unit space and hit exactly there.
#ifndef G3D_MATH_H
#define G3D_MATH_H

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include <time.h>
#include <stdint.h>

#ifdef __CUDACC__
  #define HD __host__ __device__
#else
  #define HD
#endif

#define G3_MAXDEV  8
#define G3_MAXOBJ  4096
#define G3_TEX     128
#define G3_MAXTEX  64
#define G3_CHUNK   128
#define G3_MAXAA   16
#define G3_PI      3.14159265f

enum { SH_BOX = 0, SH_SPHERE, SH_CYL, SH_CONE, SH_PYRAMID, SH_DIAMOND, SH_COUNT };
enum { F_WIRE = 1, F_OUTLINE = 2, F_SHINY = 4, F_FLAT = 8, F_HIDDEN = 16 };

struct V3 { float x, y, z; };

struct Obj {
    float r[9];             // rotation, row-major: world = R * local
    float cx, cy, cz;       // centre (pixels)
    float hx, hy, hz;       // half sizes (pixels)
    float x0, y0, x1, y1;   // screen rectangle the shape can touch
    uint32_t color;
    int tex, type, flags;
};

struct View {
    int W, H;
    float f;                // focal length in pixels; <= 0 = orthographic (no perspective)
    float vx, vy;           // vanishing point (pixels)
    V3 L;                   // unit vector toward the light
    float amb;              // ambient light 0..1
    float lw;               // wire / outline line width in pixels
    int aa;                 // samples per pixel: 1, 4, 9 or 16
    int fill;               // 1 = paint bg under empty pixels
    uint32_t bg;
    float fogNear, fogFar;  // depth fog in z pixels; fogFar <= fogNear = off
    uint32_t fogColor;
};

// ---------------------------------------------------------------- shape math (CPU and GPU)

HD inline V3 v3(float x, float y, float z) { V3 r; r.x = x; r.y = y; r.z = z; return r; }
HD inline V3 vadd(V3 a, V3 b) { return v3(a.x + b.x, a.y + b.y, a.z + b.z); }
HD inline V3 vsub(V3 a, V3 b) { return v3(a.x - b.x, a.y - b.y, a.z - b.z); }
HD inline V3 vmul(V3 a, float s) { return v3(a.x * s, a.y * s, a.z * s); }
HD inline float vdot(V3 a, V3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
HD inline V3 vnorm(V3 a)
{
    float l = sqrtf(vdot(a, a));
    return (l > 1e-20f) ? vmul(a, 1.0f / l) : v3(0, 0, -1);
}
HD inline float clamp01(float v) { return fminf(fmaxf(v, 0.0f), 1.0f); }

// planes of the flat-sided shapes in unit space: n . p <= d

HD inline int poly_planes(int type, int k, V3 &n, float &d)
{
    // box: |x|,|y|,|z| <= 1
    // pyramid: square base at y = +1 (the bottom on screen), apex at y = -1
    // diamond: |x| + |y| + |z| <= 1
    if (type == SH_BOX) {
        if (k >= 6) return 0;
        float s = (k & 1) ? -1.0f : 1.0f;
        int a = k >> 1;
        n = v3(a == 0 ? s : 0.0f, a == 1 ? s : 0.0f, a == 2 ? s : 0.0f);
        d = 1.0f;
        return 1;
    }
    if (type == SH_PYRAMID) {
        if (k >= 5) return 0;
        d = (k == 0) ? 1.0f : 0.5f;
        switch (k) {
            case 0: n = v3(0, 1, 0); break;
            case 1: n = v3(1, -0.5f, 0); break;
            case 2: n = v3(-1, -0.5f, 0); break;
            case 3: n = v3(0, -0.5f, 1); break;
            default: n = v3(0, -0.5f, -1); break;
        }
        return 1;
    }
    if (type == SH_DIAMOND) {
        if (k >= 8) return 0;
        n = v3((k & 1) ? -1.0f : 1.0f, (k & 2) ? -1.0f : 1.0f, (k & 4) ? -1.0f : 1.0f);
        d = 1.0f;
        return 1;
    }
    return 0;
}

HD inline int is_poly(int type) { return type == SH_BOX || type == SH_PYRAMID || type == SH_DIAMOND; }

// convex polyhedron (Cyrus-Beck): entry and exit along o + t*d
HD inline bool clip_planes(int type, V3 o, V3 dd, float &t0, float &t1, V3 &n0, V3 &n1)
{
    V3 n;
    float d;
    t0 = -1e30f; t1 = 1e30f;
    n0 = v3(0, 0, -1); n1 = v3(0, 0, 1);
    for (int k = 0; poly_planes(type, k, n, d); k++) {
        float dn = vdot(n, dd), num = d - vdot(n, o);
        if (fabsf(dn) < 1e-12f) {
            if (num < 0.0f) return false;
            continue;
        }
        float t = num / dn;
        if (dn < 0.0f) { if (t > t0) { t0 = t; n0 = n; } }
        else           { if (t < t1) { t1 = t; n1 = n; } }
        if (t0 > t1) return false;
    }
    return true;
}

HD inline V3 quad_normal(int type, V3 u)
{
    if (type == SH_SPHERE) return u;
    if (type == SH_CYL) return v3(u.x, 0.0f, u.z);
    return v3(u.x, -(u.y + 1.0f) * 0.25f, u.z);          // cone
}

// Ray in the shape's unit space. Returns the entry/exit t and unit-space normals.
HD inline bool isect_unit(int type, V3 o, V3 d, float &t0, float &t1, V3 &n0, V3 &n1)
{
    if (is_poly(type)) return clip_planes(type, o, d, t0, t1, n0, n1);

    // slab y in [-1, 1] for cylinder and cone (none for the sphere)
    float s0 = -1e30f, s1 = 1e30f;
    V3 sn0 = v3(0, -1, 0), sn1 = v3(0, 1, 0);
    if (type != SH_SPHERE) {
        if (fabsf(d.y) < 1e-12f) {
            if (fabsf(o.y) > 1.0f) return false;
        } else {
            float ta = (-1.0f - o.y) / d.y, tb = (1.0f - o.y) / d.y;
            if (ta < tb) { s0 = ta; s1 = tb; sn0 = v3(0, -1, 0); sn1 = v3(0, 1, 0); }
            else         { s0 = tb; s1 = ta; sn0 = v3(0, 1, 0); sn1 = v3(0, -1, 0); }
        }
    }

    // quadric f(t) = a t^2 + 2 b t + c, inside where f <= 0
    float a, b, c;
    if (type == SH_SPHERE) {
        a = vdot(d, d); b = vdot(o, d); c = vdot(o, o) - 1.0f;
    } else if (type == SH_CYL) {
        a = d.x * d.x + d.z * d.z; b = o.x * d.x + o.z * d.z; c = o.x * o.x + o.z * o.z - 1.0f;
    } else {
        float w = o.y + 1.0f;
        a = d.x * d.x + d.z * d.z - 0.25f * d.y * d.y;
        b = o.x * d.x + o.z * d.z - 0.25f * w * d.y;
        c = o.x * o.x + o.z * o.z - 0.25f * w * w;
    }

    // up to two pieces of the ray lie inside the quadric
    float pa[2], pb[2];
    int np = 0;
    if (fabsf(a) < 1e-12f) {
        if (fabsf(b) < 1e-12f) {
            if (c > 0.0f) return false;
            pa[0] = -1e30f; pb[0] = 1e30f; np = 1;
        } else {
            float r = -c / (2.0f * b);
            if (b > 0.0f) { pa[0] = -1e30f; pb[0] = r; }
            else          { pa[0] = r; pb[0] = 1e30f; }
            np = 1;
        }
    } else {
        float disc = b * b - a * c;
        if (a > 0.0f) {
            if (disc < 0.0f) return false;
            float sq = sqrtf(disc);
            pa[0] = (-b - sq) / a; pb[0] = (-b + sq) / a; np = 1;
        } else {
            if (disc < 0.0f) { pa[0] = -1e30f; pb[0] = 1e30f; np = 1; }
            else {
                float sq = sqrtf(disc);
                float r1 = (-b - sq) / a, r2 = (-b + sq) / a;
                if (r1 > r2) { float tmp = r1; r1 = r2; r2 = tmp; }
                pa[0] = -1e30f; pb[0] = r1;
                pa[1] = r2; pb[1] = 1e30f;
                np = 2;
            }
        }
    }

    // the part of one piece that is inside the slab (the solid is convex, so at most one counts)
    for (int k = 0; k < np; k++) {
        float lo = pa[k], hi = pb[k];
        V3 nlo, nhi;
        if (s0 > lo) { lo = s0; nlo = sn0; } else nlo = quad_normal(type, vadd(o, vmul(d, lo)));
        if (s1 < hi) { hi = s1; nhi = sn1; } else nhi = quad_normal(type, vadd(o, vmul(d, hi)));
        if (lo <= hi && hi > -1e29f && lo < 1e29f) {
            // the cone's lower nappe (y < -1) is not part of the shape
            if (type == SH_CONE && o.y + d.y * 0.5f * (lo + hi) < -1.0f) continue;
            t0 = lo; t1 = hi; n0 = nlo; n1 = nhi;
            return true;
        }
    }
    return false;
}

// the pixel ray for screen position (sx, sy)
HD inline void make_ray(const View &v, float sx, float sy, V3 &O, V3 &D)
{
    if (v.f > 0.0f) { O = v3(v.vx, v.vy, -v.f); D = v3(sx - v.vx, sy - v.vy, v.f); }
    else            { O = v3(sx, sy, 0.0f); D = v3(0.0f, 0.0f, 1.0f); }
}

HD inline float near_t(const View &v) { return (v.f > 0.0f) ? 0.02f : -1e7f; }

// screen pixels per object pixel at ray parameter t
HD inline float pix_scale(const View &v, float t) { return (v.f > 0.0f) ? 1.0f / fmaxf(t, 1e-4f) : 1.0f; }

// world ray -> the shape's unit space (where it is a unit box, sphere, ...)
HD inline void to_unit(const Obj &o, V3 O, V3 D, V3 &ou, V3 &du)
{
    V3 q = v3(O.x - o.cx, O.y - o.cy, O.z - o.cz);
    ou = v3((o.r[0] * q.x + o.r[3] * q.y + o.r[6] * q.z) / o.hx,
            (o.r[1] * q.x + o.r[4] * q.y + o.r[7] * q.z) / o.hy,
            (o.r[2] * q.x + o.r[5] * q.y + o.r[8] * q.z) / o.hz);
    du = v3((o.r[0] * D.x + o.r[3] * D.y + o.r[6] * D.z) / o.hx,
            (o.r[1] * D.x + o.r[4] * D.y + o.r[7] * D.z) / o.hy,
            (o.r[2] * D.x + o.r[5] * D.y + o.r[8] * D.z) / o.hz);
}

// unit-space normal -> world normal
HD inline V3 to_world_normal(const Obj &o, V3 n)
{
    V3 m = v3(n.x / o.hx, n.y / o.hy, n.z / o.hz);
    return vnorm(v3(o.r[0] * m.x + o.r[1] * m.y + o.r[2] * m.z,
                    o.r[3] * m.x + o.r[4] * m.y + o.r[5] * m.z,
                    o.r[6] * m.x + o.r[7] * m.y + o.r[8] * m.z));
}

// distance (in screen pixels) from angle a to the nearest multiple of step, on a circle of radius rr pixels
HD inline float angle_gap(float a, float step, float rr)
{
    float k = floorf(a / step + 0.5f);
    return fabsf(a - k * step) * rr;
}

// Is unit-space point u on an edge or grid line of the shape? lw is in screen pixels.
HD inline bool on_edge(const Obj &o, V3 u, float scale, float lw)
{
    float lim = lw / scale;               // line width in the shape's own pixels
    int type = o.type;
    if (is_poly(type)) {
        V3 n;
        float d;
        int close = 0;
        for (int k = 0; poly_planes(type, k, n, d); k++) {
            V3 nl = v3(n.x / o.hx, n.y / o.hy, n.z / o.hz);
            float dist = (d - vdot(n, u)) / sqrtf(vdot(nl, nl));
            if (dist < lim) close++;
        }
        return close >= 2;
    }
    float hr = 0.5f * (o.hx + o.hz);
    if (type == SH_SPHERE) {
        float rr = (o.hx + o.hy + o.hz) * (1.0f / 3.0f);
        float lat = asinf(fminf(fmaxf(u.y, -1.0f), 1.0f));
        float step = G3_PI / 6.0f;
        float k = floorf(lat / step + 0.5f);
        if (fabsf(k) < 2.5f && fabsf(lat - k * step) * rr < lim) return true;
        float cl = cosf(lat);
        if (cl > 0.12f && angle_gap(atan2f(u.z, u.x), step, rr * cl) < lim) return true;
        return false;
    }
    float rad = sqrtf(u.x * u.x + u.z * u.z);
    float rim = (type == SH_CYL) ? 1.0f : 0.5f * (u.y + 1.0f);     // radius of the side surface at this height
    float dSide = (rim - rad) * hr;
    float dCap = (type == SH_CYL) ? (1.0f - fabsf(u.y)) * o.hy : (1.0f - u.y) * o.hy;
    if (dCap < lim && dSide < lim) return true;                     // a rim
    if (dSide < lim && rad > 1e-3f) {                               // lines down the side
        if (angle_gap(atan2f(u.z, u.x), G3_PI / 4.0f, rad * hr) < lim) return true;
    }
    return false;
}

// Nearest visible hit of one shape along O + t*D. side 0 = front surface, 1 = back.
HD inline bool obj_hit(const Obj &o, const View &v, V3 O, V3 D, float &t, int &side)
{
    V3 ou, du, n0, n1;
    float t0, t1, tmin = near_t(v);
    to_unit(o, O, D, ou, du);
    if (!isect_unit(o.type, ou, du, t0, t1, n0, n1)) return false;
    if (o.flags & F_WIRE) {
        if (t0 > tmin && on_edge(o, vadd(ou, vmul(du, t0)), pix_scale(v, t0), v.lw)) { t = t0; side = 0; return true; }
        if (!(o.flags & F_HIDDEN) && t1 > tmin && on_edge(o, vadd(ou, vmul(du, t1)), pix_scale(v, t1), v.lw)) { t = t1; side = 1; return true; }
        return false;
    }
    if (t0 > tmin) { t = t0; side = 0; return true; }
    if (t1 > tmin) { t = t1; side = 1; return true; }     // eye inside the shape: see its inside
    return false;
}

HD inline V3 unpack(uint32_t c)
{
    return v3(((c >> 16) & 255) * (1.0f / 255.0f), ((c >> 8) & 255) * (1.0f / 255.0f), (c & 255) * (1.0f / 255.0f));
}

HD inline V3 tex_sample(const uint32_t *tex, int id, float U, float V)
{
    const uint32_t *t = tex + (size_t)id * G3_TEX * G3_TEX;
    float fx = U * G3_TEX - 0.5f, fy = V * G3_TEX - 0.5f;
    float x0f = floorf(fx), y0f = floorf(fy);
    float ax = fx - x0f, ay = fy - y0f;
    int x0 = ((int)x0f) & (G3_TEX - 1), y0 = ((int)y0f) & (G3_TEX - 1);
    int x1 = (x0 + 1) & (G3_TEX - 1), y1 = (y0 + 1) & (G3_TEX - 1);
    V3 a = unpack(t[y0 * G3_TEX + x0]), b = unpack(t[y0 * G3_TEX + x1]);
    V3 c = unpack(t[y1 * G3_TEX + x0]), d = unpack(t[y1 * G3_TEX + x1]);
    V3 top = vadd(vmul(a, 1.0f - ax), vmul(b, ax));
    V3 bot = vadd(vmul(c, 1.0f - ax), vmul(d, ax));
    return vadd(vmul(top, 1.0f - ay), vmul(bot, ay));
}

// texture coordinates for a unit-space hit
HD inline void shape_uv(int type, V3 u, V3 n, float &U, float &V)
{
    float anx = fabsf(n.x), any = fabsf(n.y), anz = fabsf(n.z);
    if (is_poly(type)) {
        if (anx >= any && anx >= anz) { U = u.z; V = u.y; }
        else if (any >= anz)          { U = u.x; V = u.z; }
        else                          { U = u.x; V = u.y; }
        U = (U + 1.0f) * 0.5f; V = (V + 1.0f) * 0.5f;
        return;
    }
    if (type == SH_SPHERE) {
        U = atan2f(u.z, u.x) * (0.5f / G3_PI) + 0.5f;
        V = acosf(fminf(fmaxf(-u.y, -1.0f), 1.0f)) * (1.0f / G3_PI);
        return;
    }
    if (any > 0.9f * sqrtf(n.x * n.x + n.y * n.y + n.z * n.z) && fabsf(fabsf(u.y) - 1.0f) < 1e-3f) {
        U = (u.x + 1.0f) * 0.5f; V = (u.z + 1.0f) * 0.5f;                       // a flat cap
    } else {
        U = atan2f(u.z, u.x) * (0.5f / G3_PI) + 0.5f; V = (u.y + 1.0f) * 0.5f;  // round side
    }
}

// Colour (0..1 rgb) of a hit found by obj_hit
HD inline V3 shade_hit(const Obj &o, const View &v, const uint32_t *tex, V3 O, V3 D, float t, int side)
{
    V3 ou, du, n0, n1;
    float t0, t1;
    to_unit(o, O, D, ou, du);
    isect_unit(o.type, ou, du, t0, t1, n0, n1);
    V3 u = vadd(ou, vmul(du, t));
    V3 nu = side ? n1 : n0;
    V3 base = unpack(o.color), col;

    if (o.flags & F_WIRE) {
        col = side ? vmul(base, 0.45f) : base;
    } else {
        if (o.tex > 0 && o.tex < G3_MAXTEX && tex) {
            float U, V;
            shape_uv(o.type, u, nu, U, V);
            V3 tc = tex_sample(tex, o.tex, U, V);
            base = v3(base.x * tc.x, base.y * tc.y, base.z * tc.z);
        }
        V3 n = to_world_normal(o, nu);
        if (vdot(n, D) > 0.0f) n = vmul(n, -1.0f);         // face the viewer (inside views)
        if (o.flags & F_FLAT) {
            col = base;
        } else {
            float k = v.amb + (1.0f - v.amb) * fmaxf(vdot(n, v.L), 0.0f);
            col = vmul(base, k);
            if (o.flags & F_SHINY) {
                V3 hv = vnorm(vadd(v.L, vnorm(vmul(D, -1.0f))));
                // round shapes get a tight bright spot; flat faces would light up all at once, so softer
                float s = is_poly(o.type) ? powf(fmaxf(vdot(n, hv), 0.0f), 90.0f) * 0.35f
                                          : powf(fmaxf(vdot(n, hv), 0.0f), 40.0f) * 0.7f;
                col = vadd(col, v3(s, s, s));
            }
        }
        if ((o.flags & F_OUTLINE) && on_edge(o, u, pix_scale(v, t), v.lw)) col = vmul(col, 0.25f);
    }

    if (v.fogFar > v.fogNear) {
        float z = O.z + t * D.z;
        float ff = clamp01((z - v.fogNear) / (v.fogFar - v.fogNear));
        V3 fc = unpack(v.fogColor);
        col = vadd(vmul(col, 1.0f - ff), vmul(fc, ff));
    }
    return v3(clamp01(col.x), clamp01(col.y), clamp01(col.z));
}

// sample positions inside a pixel
HD inline void aa_offset(int aa, int s, float &ox, float &oy)
{
    if (aa == 4) {
        const float tx[4] = {0.375f, 0.875f, 0.125f, 0.625f};
        const float ty[4] = {0.125f, 0.375f, 0.625f, 0.875f};
        ox = tx[s]; oy = ty[s];
        return;
    }
    int g = (aa >= 16) ? 4 : (aa >= 9) ? 3 : 1;
    ox = ((s % g) + 0.5f) / g;
    oy = ((s / g) + 0.5f) / g;
}

HD inline uint32_t pack(V3 c, float alpha)
{
    return ((uint32_t)(clamp01(alpha) * 255.0f + 0.5f) << 24) | ((uint32_t)(c.x * 255.0f + 0.5f) << 16)
         | ((uint32_t)(c.y * 255.0f + 0.5f) << 8) | (uint32_t)(c.z * 255.0f + 0.5f);
}

// ---------------------------------------------------------------- host-side shape setup

static void build_obj(Obj &o, int type, float x, float y, float z, float w, float h, float d,
                      float ax, float ay, float az, uint32_t color, int tex, int flags)
{
    float a = ax * (G3_PI / 180.0f), b = ay * (G3_PI / 180.0f), c = az * (G3_PI / 180.0f);
    float ca = cosf(a), sa = sinf(a), cb = cosf(b), sb = sinf(b), cc = cosf(c), sc = sinf(c);
    // R = Rz * Ry * Rx
    o.r[0] = cc * cb; o.r[1] = cc * sb * sa - sc * ca; o.r[2] = cc * sb * ca + sc * sa;
    o.r[3] = sc * cb; o.r[4] = sc * sb * sa + cc * ca; o.r[5] = sc * sb * ca - cc * sa;
    o.r[6] = -sb;     o.r[7] = cb * sa;                o.r[8] = cb * ca;
    o.cx = x; o.cy = y; o.cz = z;
    o.hx = fmaxf(fabsf(w) * 0.5f, 0.05f);
    o.hy = fmaxf(fabsf(h) * 0.5f, 0.05f);
    o.hz = fmaxf(fabsf(d) * 0.5f, 0.05f);
    o.color = color;
    o.tex = tex;
    o.type = (type >= 0 && type < SH_COUNT) ? type : SH_BOX;
    o.flags = flags;
    o.x0 = o.y0 = 0; o.x1 = o.y1 = 0;
}

// Screen rectangle of a shape (from its 8 bounding-box corners). Returns 0 if it can't be seen.
static int obj_rect(Obj &o, const View &v)
{
    float minx = 1e30f, miny = 1e30f, maxx = -1e30f, maxy = -1e30f;
    int behind = 0;
    for (int k = 0; k < 8; k++) {
        float lx = (k & 1) ? o.hx : -o.hx, ly = (k & 2) ? o.hy : -o.hy, lz = (k & 4) ? o.hz : -o.hz;
        float X = o.cx + o.r[0] * lx + o.r[1] * ly + o.r[2] * lz;
        float Y = o.cy + o.r[3] * lx + o.r[4] * ly + o.r[5] * lz;
        float Z = o.cz + o.r[6] * lx + o.r[7] * ly + o.r[8] * lz;
        float sx = X, sy = Y;
        if (v.f > 0.0f) {
            float den = Z + v.f;
            if (den < 1.0f) { behind++; continue; }
            sx = v.vx + (X - v.vx) * v.f / den;
            sy = v.vy + (Y - v.vy) * v.f / den;
        }
        minx = fminf(minx, sx); maxx = fmaxf(maxx, sx);
        miny = fminf(miny, sy); maxy = fmaxf(maxy, sy);
    }
    if (behind == 8) return 0;
    if (behind > 0) { minx = 0; miny = 0; maxx = (float)v.W; maxy = (float)v.H; }   // reaches past the eye
    float pad = v.lw + 2.0f;
    o.x0 = fmaxf(minx - pad, 0.0f); o.y0 = fmaxf(miny - pad, 0.0f);
    o.x1 = fminf(maxx + pad, (float)v.W); o.y1 = fminf(maxy + pad, (float)v.H);
    return (o.x0 < o.x1 && o.y0 < o.y1);
}

#endif // G3D_MATH_H

// rcgpu.cu - multi-GPU Wolfenstein-style ray caster library for QB64-PE  (v2)
//
// Each frame, every GPU:
//   1. steps the effect simulations (3D smoke volume, 2D water ripples) -
//      every card runs the same simulation on its own copy, so they stay in sync
//   2. casts one ray per screen column through the grid map (DDA)
//   3. draws its own horizontal band of the screen: textured walls, floor and
//      ceiling, reflective water, sprites, distance fog, ray-marched smoke
//   4. copies its band back into one pinned frame buffer
// The host then copies the finished frame into the QB64 screen image.
//
// Map cells (one byte each):
//   0        empty
//   1..63    solid wall, value = texture number
//   64..127  sliding door in the middle of the cell, texture = value - 64
// Floor and ceiling maps hold a texture number per cell (0 = none, shows fog).
// Floor value 63 (WATER_ID) = water: a reflective, rippling floor.
// Textures are 64x64, 32-bit 0xAARRGGBB (QB64 image format); alpha < 128 is
// transparent on sprites.
//
// Effects are off until set up, so v1 programs run unchanged:
//   rc_smoke_setup(res)  3D smoke grid, res voxels per map cell (and res tall)
//   rc_water_setup(res)  ripple grid, res texels per map cell
//
// The library keeps its own host copy of the map, textures, doors and sprites,
// so rc_init can be called again (e.g. with a different GPU count) without
// re-sending anything. Effect grids are re-created (empty) by rc_init.
//
// Build on Linux (CUDA 12.x; covers Maxwell and, via PTX, any newer NVIDIA card):
//   nvcc -O2 -Wno-deprecated-gpu-targets -gencode arch=compute_50,code=sm_50 -gencode arch=compute_50,code=compute_50 -Xcompiler -fPIC -shared -o librcgpu.so rcgpu.cu
//
// Build on Windows (x64 Native Tools Command Prompt for VS, CUDA 12.x):
//   nvcc -O2 -Wno-deprecated-gpu-targets -gencode arch=compute_50,code=sm_50 -gencode arch=compute_50,code=compute_50 -shared -o rcgpu.dll rcgpu.cu

#include <cuda_runtime.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include <time.h>
#include <stdint.h>

#ifdef _WIN32
  #define WIN32_LEAN_AND_MEAN
  #include <windows.h>
  #define RC_API __declspec(dllexport)
#else
  #define RC_API
#endif

#define MAXDEV   8
#define TEX      64
#define MAXTEX   64
#define MAXSPR   512
#define MAXSTEPS 512
#define WATER_ID 63
#define MAXINJ   32

struct Cam {
    float px, py;           // position (map units)
    float dx, dy;           // view direction
    float plx, ply;         // camera plane (screen right)
    int W, H;
    float fogDist;          // 0 = no fog
    uint32_t fog;           // fog / void colour
    int shade;              // darken y-side walls
};

struct ColHit {
    float dist;             // perpendicular distance, 1e30 = nothing hit
    float texX;             // 0..1 across the wall face
    int tex;                // texture number, -1 = nothing hit
    int side;               // 0 = x-side, 1 = y-side
};

struct SprP {               // sprite projected to the screen
    float sx, top, w, h, depth;
    int tex;
};

struct Inj { float x, y, amt, r; };          // a smoke puff or a water drop
struct InjList { int n; Inj v[MAXINJ]; };    // passed to kernels by value

struct SmokeP {             // smoke simulation step
    float t, dt, rise, swirl, windx, windy, decay;
    int vx, vy, vz, res;
};

struct FxR {                // what the pixel kernel needs from the effects
    const float *vol;       // smoke density grid (NULL = off)
    int vx, vy, vz, sres, steps;
    float sigma;
    const float *wave;      // ripple height grid (NULL = off)
    int wvx, wvy, wres;
    unsigned int frame;
};

struct Dev {
    int y0, rows;           // this GPU's band of screen rows
    uint8_t *walls, *floors, *ceils;
    float *doors;
    uint32_t *tex;
    SprP *spr;
    ColHit *cols;
    uint32_t *band;
    float *smoke[2];        // ping-pong smoke grids
    float *wave[2];         // ping-pong ripple grids
    cudaStream_t st;
    cudaEvent_t e0, e1;
    float kms;
};

static Dev g_dev[MAXDEV];
static float g_weight[MAXDEV];
static int g_ndev = 0, g_W = 0, g_H = 0, g_mw = 0, g_mh = 0;
static uint8_t *g_walls = NULL, *g_floors = NULL, *g_ceils = NULL;
static float *g_doors = NULL;
static uint32_t g_tex[MAXTEX * TEX * TEX];
static float g_sprites[MAXSPR * 4];
static int g_nspr = 0;
static uint32_t *g_stage = NULL;        // pinned full frame
static SprP *g_sprP = NULL;             // pinned projected sprites
static Cam g_cam;
static float g_gpuMs = 0, g_hostMs = 0;
static char g_err[512] = "";

// effects state (identical on every GPU)
static int g_sres = 0, g_svx = 0, g_svy = 0, g_svz = 0, g_scur = 0;
static int g_wres = 0, g_wvx = 0, g_wvy = 0, g_wcur = 0;
static float g_time = 0.0f, g_dt = 1.0f / 60.0f, g_wacc = 0.0f;
static float g_rise = 0.22f, g_swirl = 0.35f, g_decay = 0.93f, g_sigma = 2.5f;
static int g_steps = 32;
static float g_rain = 0.0f, g_damp = 0.985f;
static InjList g_sq, g_wq;
static unsigned int g_frame = 0, g_rng = 2463534242u;

static int chk(cudaError_t e, const char *where)
{
    if (e != cudaSuccess) {
        snprintf(g_err, sizeof g_err, "%s: %s", where, cudaGetErrorString(e));
        return 0;
    }
    return 1;
}

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

static float rnd01(void)
{
    g_rng ^= g_rng << 13; g_rng ^= g_rng >> 17; g_rng ^= g_rng << 5;
    return (g_rng >> 8) * (1.0f / 16777216.0f);
}

// ---------------------------------------------------------------- device side

__device__ __forceinline__ unsigned int hash32(unsigned int x)
{
    x ^= x >> 16; x *= 0x7feb352dU;
    x ^= x >> 15; x *= 0x846ca68bU;
    x ^= x >> 16;
    return x;
}

__device__ __forceinline__ float fogf(const Cam &c, float d)
{
    return (c.fogDist > 0.0f) ? __expf(-d / c.fogDist) : 1.0f;
}

__device__ __forceinline__ uint32_t shade(uint32_t t, float k, float f, uint32_t fog)
{
    float r = ((t >> 16) & 255) * k, g = ((t >> 8) & 255) * k, b = (t & 255) * k;
    float fr = (float)((fog >> 16) & 255), fg = (float)((fog >> 8) & 255), fb = (float)(fog & 255);
    r = fminf(r * f + fr * (1.0f - f), 255.0f);
    g = fminf(g * f + fg * (1.0f - f), 255.0f);
    b = fminf(b * f + fb * (1.0f - f), 255.0f);
    return 0xFF000000u | ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
}

__device__ __forceinline__ uint32_t mix32(uint32_t a, uint32_t b, float t)
{
    float s = 1.0f - t;
    float r = ((a >> 16) & 255) * s + ((b >> 16) & 255) * t;
    float g = ((a >> 8) & 255) * s + ((b >> 8) & 255) * t;
    float bl = (a & 255) * s + (b & 255) * t;
    return 0xFF000000u | ((uint32_t)fminf(r, 255.0f) << 16) | ((uint32_t)fminf(g, 255.0f) << 8) | (uint32_t)fminf(bl, 255.0f);
}

// ---- 3D smoke grid: index = (z * vy + y) * vx + x

__device__ __forceinline__ float vfetch(const float *v, int vx, int vy, int vz, int x, int y, int z)
{
    if (x < 0 || y < 0 || x >= vx || y >= vy) return 0.0f;
    z = min(max(z, 0), vz - 1);
    return v[((size_t)z * vy + y) * vx + x];
}

// trilinear sample; coordinates in voxel units (voxel centres at i + 0.5)
__device__ float vol_sample(const float *v, int vx, int vy, int vz, float fx, float fy, float fz)
{
    fx -= 0.5f; fy -= 0.5f; fz -= 0.5f;
    int x0 = (int)floorf(fx), y0 = (int)floorf(fy), z0 = (int)floorf(fz);
    float ax = fx - x0, ay = fy - y0, az = fz - z0;
    float c00 = vfetch(v, vx, vy, vz, x0, y0, z0) * (1 - ax) + vfetch(v, vx, vy, vz, x0 + 1, y0, z0) * ax;
    float c10 = vfetch(v, vx, vy, vz, x0, y0 + 1, z0) * (1 - ax) + vfetch(v, vx, vy, vz, x0 + 1, y0 + 1, z0) * ax;
    float c01 = vfetch(v, vx, vy, vz, x0, y0, z0 + 1) * (1 - ax) + vfetch(v, vx, vy, vz, x0 + 1, y0, z0 + 1) * ax;
    float c11 = vfetch(v, vx, vy, vz, x0, y0 + 1, z0 + 1) * (1 - ax) + vfetch(v, vx, vy, vz, x0 + 1, y0 + 1, z0 + 1) * ax;
    float c0 = c00 * (1 - ay) + c10 * ay;
    float c1 = c01 * (1 - ay) + c11 * ay;
    return c0 * (1 - az) + c1 * az;
}

// One smoke step: semi-Lagrangian advection through a drifting, swirling,
// rising wind field, slow fade, new puffs near the floor, walls stay empty.
// One thread per (x, y) column of voxels.
__global__ void k_smoke_step(const float *src, float *dst, const uint8_t *walls, const float *doors,
                             int mw, int mh, SmokeP sp, InjList inj)
{
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= sp.vx || y >= sp.vy) return;

    size_t plane = (size_t)sp.vx * sp.vy;
    size_t col = (size_t)y * sp.vx + x;
    int cell = (y / sp.res) * mw + (x / sp.res);
    int w = walls[cell];
    if (w > 0 && (w < 64 || doors[cell] < 0.5f)) {
        for (int z = 0; z < sp.vz; z++) dst[z * plane + col] = 0.0f;
        return;
    }

    float ir = 1.0f / sp.res;
    float wx = (x + 0.5f) * ir, wy = (y + 0.5f) * ir;
    float back = sp.dt * sp.res;
    for (int z = 0; z < sp.vz; z++) {
        float wz = (z + 0.5f) * ir;
        float u = sp.windx + sp.swirl * __sinf(wy * 1.7f + sp.t * 0.6f + wz * 2.0f);
        float v = sp.windy + sp.swirl * __cosf(wx * 1.9f - sp.t * 0.5f + wz * 1.6f);
        float up = sp.rise * (1.0f - 0.5f * wz);
        float d = vol_sample(src, sp.vx, sp.vy, sp.vz,
                             x + 0.5f - u * back, y + 0.5f - v * back, z + 0.5f - up * back) * sp.decay;
        if (wz < 0.5f) {
            for (int k = 0; k < inj.n; k++) {
                float ddx = wx - inj.v[k].x, ddy = wy - inj.v[k].y;
                float r2 = inj.v[k].r * inj.v[k].r, d2 = ddx * ddx + ddy * ddy;
                if (d2 < r2) d += inj.v[k].amt * sp.dt * (1.0f - d2 / r2);
            }
        }
        dst[z * plane + col] = fminf(d, 6.0f);
    }
}

// ---- 2D ripple grid

__device__ __forceinline__ float wfetch(const float *w, int wvx, int wvy, int x, int y)
{
    if (x < 0 || y < 0 || x >= wvx || y >= wvy) return 0.0f;
    return w[(size_t)y * wvx + x];
}

__device__ float wsample(const float *w, int wvx, int wvy, float fx, float fy)
{
    fx -= 0.5f; fy -= 0.5f;
    int x0 = (int)floorf(fx), y0 = (int)floorf(fy);
    float ax = fx - x0, ay = fy - y0;
    float a = wfetch(w, wvx, wvy, x0, y0) * (1 - ax) + wfetch(w, wvx, wvy, x0 + 1, y0) * ax;
    float b = wfetch(w, wvx, wvy, x0, y0 + 1) * (1 - ax) + wfetch(w, wvx, wvy, x0 + 1, y0 + 1) * ax;
    return a * (1 - ay) + b * ay;
}

// Classic two-buffer wave equation: b holds the step before last and receives
// the new heights. Only water cells move; everything else is held at zero.
__global__ void k_wave(const float *a, float *b, int wvx, int wvy, int wres,
                       const uint8_t *floors, int mw, float damp, InjList drops)
{
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= wvx || y >= wvy) return;
    size_t i = (size_t)y * wvx + x;
    if (floors[(y / wres) * mw + (x / wres)] != WATER_ID) { b[i] = 0.0f; return; }

    float n = wfetch(a, wvx, wvy, x - 1, y) + wfetch(a, wvx, wvy, x + 1, y)
            + wfetch(a, wvx, wvy, x, y - 1) + wfetch(a, wvx, wvy, x, y + 1);
    float v = (n * 0.5f - b[i]) * damp;
    float fx = (x + 0.5f) / wres, fy = (y + 0.5f) / wres;
    for (int k = 0; k < drops.n; k++) {
        float ddx = fx - drops.v[k].x, ddy = fy - drops.v[k].y;
        float r2 = drops.v[k].r * drops.v[k].r, d2 = ddx * ddx + ddy * ddy;
        if (d2 < r2) v += drops.v[k].amt * (1.0f - d2 / r2);
    }
    b[i] = v;
}

// One ray per screen column
__global__ void k_columns(Cam c, const uint8_t *walls, const float *doors, int mw, int mh, ColHit *cols)
{
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    if (x >= c.W) return;

    float camX = 2.0f * (x + 0.5f) / c.W - 1.0f;
    float rdx = c.dx + c.plx * camX, rdy = c.dy + c.ply * camX;
    int mapX = (int)floorf(c.px), mapY = (int)floorf(c.py);
    float ddx = (rdx == 0.0f) ? 1e30f : fabsf(1.0f / rdx);
    float ddy = (rdy == 0.0f) ? 1e30f : fabsf(1.0f / rdy);
    int stepX, stepY;
    float sdx, sdy;
    if (rdx < 0) { stepX = -1; sdx = (c.px - mapX) * ddx; } else { stepX = 1; sdx = (mapX + 1.0f - c.px) * ddx; }
    if (rdy < 0) { stepY = -1; sdy = (c.py - mapY) * ddy; } else { stepY = 1; sdy = (mapY + 1.0f - c.py) * ddy; }

    ColHit h;
    h.dist = 1e30f; h.texX = 0.0f; h.tex = -1; h.side = 0;

    for (int i = 0; i < MAXSTEPS; i++) {
        int side;
        if (sdx < sdy) { sdx += ddx; mapX += stepX; side = 0; }
        else           { sdy += ddy; mapY += stepY; side = 1; }
        if (mapX < 0 || mapY < 0 || mapX >= mw || mapY >= mh) break;

        int w = walls[mapY * mw + mapX];
        if (w == 0) continue;

        if (w < 64) {
            float perp = (side == 0) ? sdx - ddx : sdy - ddy;
            float wx = (side == 0) ? c.py + perp * rdy : c.px + perp * rdx;
            wx -= floorf(wx);
            if (side == 0 && rdx > 0) wx = 1.0f - wx;
            if (side == 1 && rdy < 0) wx = 1.0f - wx;
            h.dist = perp; h.texX = wx; h.tex = w; h.side = side;
            break;
        } else {
            // sliding door, half a cell in from the face the ray entered
            float open = doors[mapY * mw + mapX];
            float perp, next;
            if (side == 0) { perp = sdx - ddx * 0.5f; next = sdy; }
            else           { perp = sdy - ddy * 0.5f; next = sdx; }
            if (perp > next) continue;
            float wx = (side == 0) ? c.py + perp * rdy : c.px + perp * rdx;
            wx -= floorf(wx);
            if (wx < open) continue;
            h.dist = perp; h.texX = wx - open; h.tex = w - 64; h.side = side;
            break;
        }
    }
    cols[x] = h;
}

// Water floor: a mirror of the walls and ceiling, bent by the ripple slopes
__device__ uint32_t water_color(const Cam &c, int x, float yf, float halfH, float ap, float rowDist,
                                float wx, float wy, const ColHit *cols, const uint8_t *ceils,
                                int mw, int mh, const uint32_t *tex, const FxR &fx)
{
    float gx = 0.0f, gy = 0.0f;
    if (fx.wave) {
        float sx = wx * fx.wres, sy = wy * fx.wres;
        gx = wsample(fx.wave, fx.wvx, fx.wvy, sx + 1.0f, sy) - wsample(fx.wave, fx.wvx, fx.wvy, sx - 1.0f, sy);
        gy = wsample(fx.wave, fx.wvx, fx.wvy, sx, sy + 1.0f) - wsample(fx.wave, fx.wvx, fx.wvy, sx, sy - 1.0f);
    }
    float k = 24.0f / fmaxf(rowDist, 0.8f);
    int rx = min(max(x + (int)(gx * k), 0), c.W - 1);
    float yr = fmaxf(yf + gy * k, halfH + 1.0f);

    ColHit hr = cols[rx];
    uint32_t rcol;
    float rdist;
    float lineH2 = (hr.tex >= 0) ? c.H / hr.dist : 0.0f;
    float bot2 = halfH + lineH2 * 0.5f;
    if (hr.tex >= 0 && yr < bot2 + lineH2) {
        // the wall, upside down below its own base
        float y2 = fmaxf(yr, bot2);
        int tx = min((int)(hr.texX * TEX), TEX - 1);
        int ty = min(max((int)((bot2 + lineH2 - y2) / lineH2 * TEX), 0), TEX - 1);
        float sk = (c.shade && hr.side == 1) ? 0.72f : 1.0f;
        rdist = hr.dist;
        rcol = shade(tex[hr.tex * TEX * TEX + ty * TEX + tx], sk, fogf(c, rdist), c.fog);
    } else {
        // the ceiling, mirrored below the floor
        float camX2 = 2.0f * (rx + 0.5f) / c.W - 1.0f;
        float rdx2 = c.dx + c.plx * camX2, rdy2 = c.dy + c.ply * camX2;
        rdist = 1.5f * c.H / fmaxf(yr - halfH, 0.5f);
        float qx = c.px + rdist * rdx2, qy = c.py + rdist * rdy2;
        int qcx = (int)floorf(qx), qcy = (int)floorf(qy), ti = 0;
        if (qcx >= 0 && qcy >= 0 && qcx < mw && qcy < mh) ti = ceils[qcy * mw + qcx];
        if (ti <= 0 || ti >= MAXTEX || ti == WATER_ID) {
            rcol = c.fog | 0xFF000000u;
        } else {
            int tx = (int)((qx - floorf(qx)) * TEX) & (TEX - 1);
            int ty = (int)((qy - floorf(qy)) * TEX) & (TEX - 1);
            rcol = shade(tex[ti * TEX * TEX + ty * TEX + tx], 0.8f, fogf(c, rdist), c.fog);
        }
    }
    uint32_t base = shade(0xFF16323Eu, 1.0f, fogf(c, rowDist), c.fog);
    float fres = 1.0f - fminf(ap / halfH, 1.0f);          // more mirror-like at grazing angles
    return mix32(base, rcol, 0.35f + 0.55f * fres * fres);
}

// Every pixel in this GPU's band
__global__ void k_pixels(Cam c, int y0, int rows, const ColHit *cols,
                         const uint8_t *floors, const uint8_t *ceils, int mw, int mh,
                         const uint32_t *tex, const SprP *spr, int nspr, FxR fx, uint32_t *band)
{
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int yy = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= c.W || yy >= rows) return;
    int y = y0 + yy;
    float yf = y + 0.5f;
    float halfH = c.H * 0.5f;
    float camX = 2.0f * (x + 0.5f) / c.W - 1.0f;
    float rdx = c.dx + c.plx * camX, rdy = c.dy + c.ply * camX;

    ColHit h = cols[x];
    uint32_t out;
    float depth;

    float lineH = (h.tex >= 0) ? c.H / h.dist : 0.0f;
    float top = halfH - lineH * 0.5f, bot = halfH + lineH * 0.5f;

    if (h.tex >= 0 && yf >= top && yf < bot) {
        int tx = min((int)(h.texX * TEX), TEX - 1);
        int ty = min(max((int)((yf - top) / lineH * TEX), 0), TEX - 1);
        uint32_t t = tex[h.tex * TEX * TEX + ty * TEX + tx];
        float k = (c.shade && h.side == 1) ? 0.72f : 1.0f;
        depth = h.dist;
        out = shade(t, k, fogf(c, depth), c.fog);
    } else {
        float p = yf - halfH;
        int isFloor = (p > 0.0f);
        float ap = fmaxf(fabsf(p), 0.5f);
        float rowDist = halfH / ap;
        float wx = c.px + rowDist * rdx, wy = c.py + rowDist * rdy;
        int cx = (int)floorf(wx), cy = (int)floorf(wy);
        int ti = 0;
        if (cx >= 0 && cy >= 0 && cx < mw && cy < mh)
            ti = isFloor ? floors[cy * mw + cx] : ceils[cy * mw + cx];
        depth = rowDist;
        if (isFloor && ti == WATER_ID) {
            out = water_color(c, x, yf, halfH, ap, rowDist, wx, wy, cols, ceils, mw, mh, tex, fx);
        } else if (ti <= 0 || ti >= MAXTEX) {
            out = c.fog | 0xFF000000u;
        } else {
            int tx = (int)((wx - floorf(wx)) * TEX) & (TEX - 1);
            int ty = (int)((wy - floorf(wy)) * TEX) & (TEX - 1);
            uint32_t t = tex[ti * TEX * TEX + ty * TEX + tx];
            out = shade(t, isFloor ? 0.9f : 0.8f, fogf(c, depth), c.fog);
        }
    }

    // sprites, sorted nearest first: the first solid texel in front wins
    for (int s = 0; s < nspr; s++) {
        SprP sp = spr[s];
        if (sp.depth >= depth) break;
        float lx = x + 0.5f - (sp.sx - sp.w * 0.5f);
        if (lx < 0.0f || lx >= sp.w) continue;
        float ly = yf - sp.top;
        if (ly < 0.0f || ly >= sp.h) continue;
        int tx = min((int)(lx / sp.w * TEX), TEX - 1);
        int ty = min((int)(ly / sp.h * TEX), TEX - 1);
        uint32_t t = tex[sp.tex * TEX * TEX + ty * TEX + tx];
        if ((t >> 24) < 128) continue;
        out = shade(t, 1.0f, fogf(c, sp.depth), c.fog);
        depth = sp.depth;
        break;
    }

    // smoke: march the pixel's ray from the eye to whatever it hit
    if (fx.vol) {
        float slope = (halfH - yf) / c.H;                 // height change per unit of depth
        float tmax = fminf(depth, 30.0f);
        const float t0 = 0.1f;
        if (tmax > t0) {
            int n = fx.steps;
            float dtm = (tmax - t0) / n;
            float lenT = sqrtf(rdx * rdx + rdy * rdy + slope * slope);
            unsigned int hs = hash32((unsigned)x * 1973u + (unsigned)y * 9277u + fx.frame * 26699u);
            float jit = (hs >> 8) * (1.0f / 16777216.0f);
            float fr = (float)((c.fog >> 16) & 255), fg = (float)((c.fog >> 8) & 255), fb = (float)(c.fog & 255);
            float fs = (float)fx.sres;
            float T = 1.0f, sr = 0.0f, sg = 0.0f, sb = 0.0f;
            for (int i = 0; i < n; i++) {
                float t = t0 + (i + jit) * dtm;
                float wz = 0.5f + slope * t;
                if (wz <= 0.0f || wz >= 1.0f) continue;
                float dn = vol_sample(fx.vol, fx.vx, fx.vy, fx.vz,
                                      (c.px + t * rdx) * fs, (c.py + t * rdy) * fs, wz * fs);
                if (dn > 0.001f) {
                    float a = 1.0f - __expf(-dn * fx.sigma * dtm * lenT);
                    float lum = 150.0f + 60.0f * wz;      // lighter near the ceiling
                    float f = fogf(c, t);
                    sr += T * a * (lum * f + fr * (1.0f - f));
                    sg += T * a * ((lum + 2.0f) * f + fg * (1.0f - f));
                    sb += T * a * ((lum + 8.0f) * f + fb * (1.0f - f));
                    T *= (1.0f - a);
                    if (T < 0.02f) break;
                }
            }
            if (T < 0.999f) {
                float r = ((out >> 16) & 255) * T + sr;
                float g = ((out >> 8) & 255) * T + sg;
                float b = (out & 255) * T + sb;
                out = 0xFF000000u | ((uint32_t)fminf(r, 255.0f) << 16)
                    | ((uint32_t)fminf(g, 255.0f) << 8) | (uint32_t)fminf(b, 255.0f);
            }
        }
    }

    band[yy * c.W + x] = out;
}

// ---------------------------------------------------------------- host side

static int cmp_depth(const void *a, const void *b)
{
    float da = ((const SprP *)a)->depth, db = ((const SprP *)b)->depth;
    return (da < db) ? -1 : (da > db) ? 1 : 0;
}

static void free_fx(int d)
{
    Dev &D = g_dev[d];
    cudaSetDevice(d);
    for (int k = 0; k < 2; k++) {
        if (D.smoke[k]) { cudaFree(D.smoke[k]); D.smoke[k] = NULL; }
        if (D.wave[k]) { cudaFree(D.wave[k]); D.wave[k] = NULL; }
    }
}

static size_t smoke_bytes(void) { return (size_t)g_svx * g_svy * g_svz * sizeof(float); }
static size_t wave_bytes(void) { return (size_t)g_wvx * g_wvy * sizeof(float); }

static void fx_dims(void)
{
    g_svx = g_mw * g_sres; g_svy = g_mh * g_sres; g_svz = g_sres;
    g_wvx = g_mw * g_wres; g_wvy = g_mh * g_wres;
}

// (Re)create the smoke grids on one GPU; empty grids
static int alloc_smoke(int d)
{
    Dev &D = g_dev[d];
    cudaSetDevice(d);
    for (int k = 0; k < 2; k++) if (D.smoke[k]) { cudaFree(D.smoke[k]); D.smoke[k] = NULL; }
    if (g_sres <= 0) return 1;
    for (int k = 0; k < 2; k++) {
        if (!chk(cudaMalloc(&D.smoke[k], smoke_bytes()), "smoke grid (not enough VRAM?)")) { D.smoke[k] = NULL; return 0; }
        cudaMemset(D.smoke[k], 0, smoke_bytes());
    }
    return 1;
}

static int alloc_wave(int d)
{
    Dev &D = g_dev[d];
    cudaSetDevice(d);
    for (int k = 0; k < 2; k++) if (D.wave[k]) { cudaFree(D.wave[k]); D.wave[k] = NULL; }
    if (g_wres <= 0) return 1;
    for (int k = 0; k < 2; k++) {
        if (!chk(cudaMalloc(&D.wave[k], wave_bytes()), "water grid (not enough VRAM?)")) { D.wave[k] = NULL; return 0; }
        cudaMemset(D.wave[k], 0, wave_bytes());
    }
    return 1;
}

static void free_devices(void)
{
    for (int d = 0; d < g_ndev; d++) {
        Dev &D = g_dev[d];
        cudaSetDevice(d);
        if (D.st) cudaStreamSynchronize(D.st);
        free_fx(d);
        if (D.walls) cudaFree(D.walls);
        if (D.floors) cudaFree(D.floors);
        if (D.ceils) cudaFree(D.ceils);
        if (D.doors) cudaFree(D.doors);
        if (D.tex) cudaFree(D.tex);
        if (D.spr) cudaFree(D.spr);
        if (D.cols) cudaFree(D.cols);
        if (D.band) cudaFree(D.band);
        if (D.e0) cudaEventDestroy(D.e0);
        if (D.e1) cudaEventDestroy(D.e1);
        if (D.st) cudaStreamDestroy(D.st);
        memset(&D, 0, sizeof D);
    }
    if (g_ndev > 0) cudaSetDevice(0);
    if (g_stage) { cudaFreeHost(g_stage); g_stage = NULL; }
    if (g_sprP) { cudaFreeHost(g_sprP); g_sprP = NULL; }
    g_ndev = 0;
}

static int upload_all(int d)
{
    Dev &D = g_dev[d];
    size_t n = (size_t)g_mw * g_mh;
    cudaSetDevice(d);
    if (!chk(cudaMemcpy(D.walls, g_walls, n, cudaMemcpyHostToDevice), "upload map")) return 0;
    if (!chk(cudaMemcpy(D.floors, g_floors, n, cudaMemcpyHostToDevice), "upload floors")) return 0;
    if (!chk(cudaMemcpy(D.ceils, g_ceils, n, cudaMemcpyHostToDevice), "upload ceilings")) return 0;
    if (!chk(cudaMemcpy(D.doors, g_doors, n * sizeof(float), cudaMemcpyHostToDevice), "upload doors")) return 0;
    if (!chk(cudaMemcpy(D.tex, g_tex, sizeof g_tex, cudaMemcpyHostToDevice), "upload textures")) return 0;
    return 1;
}

extern "C" {

RC_API void rc_shutdown(void)
{
    free_devices();
    free(g_walls); free(g_floors); free(g_ceils); free(g_doors);
    g_walls = g_floors = g_ceils = NULL;
    g_doors = NULL;
    g_mw = g_mh = 0;
}

// Relative share of screen rows for a GPU (call before rc_init). 1.0 = normal.
RC_API void rc_set_weight(int dev, float w)
{
    if (dev >= 0 && dev < MAXDEV) g_weight[dev] = w;
}

RC_API void rc_camera(float px, float py, float ang)
{
    float len = 0.5f * (float)g_W / (float)g_H;   // keeps pixels square
    g_cam.px = px;
    g_cam.py = py;
    g_cam.dx = cosf(ang);
    g_cam.dy = sinf(ang);
    g_cam.plx = -g_cam.dy * len;
    g_cam.ply = g_cam.dx * len;
    g_cam.W = g_W;
    g_cam.H = g_H;
}

RC_API void rc_params(float fogDist, uint32_t fogColor, int shadeSides)
{
    g_cam.fogDist = fogDist;
    g_cam.fog = fogColor;
    g_cam.shade = shadeSides;
}

RC_API int rc_init(int maxdev, int W, int H, int mw, int mh)
{
    int count = 0, y = 0;
    float w[MAXDEV], wsum = 0.0f;
    size_t n;

    free_devices();
    if (!chk(cudaGetDeviceCount(&count), "cudaGetDeviceCount")) return 0;
    if (count < 1) { snprintf(g_err, sizeof g_err, "no CUDA devices"); return 0; }
    if (W < 16 || H < 16 || mw < 1 || mh < 1) { snprintf(g_err, sizeof g_err, "bad size"); return 0; }
    if (maxdev < 1 || maxdev > count) maxdev = count;
    if (maxdev > MAXDEV) maxdev = MAXDEV;
    if (maxdev > H / 8) maxdev = H / 8;

    // host copies of the world survive re-inits of the same map size
    n = (size_t)mw * mh;
    if (mw != g_mw || mh != g_mh || !g_walls) {
        free(g_walls); free(g_floors); free(g_ceils); free(g_doors);
        g_walls = (uint8_t *)calloc(n, 1);
        g_floors = (uint8_t *)calloc(n, 1);
        g_ceils = (uint8_t *)calloc(n, 1);
        g_doors = (float *)calloc(n, sizeof(float));
        if (!g_walls || !g_floors || !g_ceils || !g_doors) {
            snprintf(g_err, sizeof g_err, "host malloc failed");
            return 0;
        }
        g_mw = mw; g_mh = mh;
    }
    g_W = W; g_H = H;
    fx_dims();

    for (int d = 0; d < maxdev; d++) {
        w[d] = (g_weight[d] > 0.0f) ? g_weight[d] : 1.0f;
        wsum += w[d];
    }

    cudaSetDevice(0);
    if (!chk(cudaHostAlloc((void **)&g_stage, (size_t)W * H * 4, cudaHostAllocPortable), "cudaHostAlloc frame")) goto fail;
    if (!chk(cudaHostAlloc((void **)&g_sprP, MAXSPR * sizeof(SprP), cudaHostAllocPortable), "cudaHostAlloc sprites")) goto fail;

    for (int d = 0; d < maxdev; d++) {
        Dev &D = g_dev[d];
        memset(&D, 0, sizeof D);
        g_ndev = d + 1;   // so a failure can clean up
        D.y0 = y;
        D.rows = (d == maxdev - 1) ? H - y : (int)((float)H * w[d] / wsum);
        y += D.rows;

        if (!chk(cudaSetDevice(d), "cudaSetDevice")) goto fail;
        if (!chk(cudaStreamCreate(&D.st), "cudaStreamCreate")) goto fail;
        if (!chk(cudaEventCreate(&D.e0), "cudaEventCreate")) goto fail;
        if (!chk(cudaEventCreate(&D.e1), "cudaEventCreate")) goto fail;
        if (!chk(cudaMalloc(&D.walls, n), "cudaMalloc map")) goto fail;
        if (!chk(cudaMalloc(&D.floors, n), "cudaMalloc floors")) goto fail;
        if (!chk(cudaMalloc(&D.ceils, n), "cudaMalloc ceilings")) goto fail;
        if (!chk(cudaMalloc(&D.doors, n * sizeof(float)), "cudaMalloc doors")) goto fail;
        if (!chk(cudaMalloc(&D.tex, sizeof g_tex), "cudaMalloc textures")) goto fail;
        if (!chk(cudaMalloc(&D.spr, MAXSPR * sizeof(SprP)), "cudaMalloc sprites")) goto fail;
        if (!chk(cudaMalloc(&D.cols, (size_t)W * sizeof(ColHit)), "cudaMalloc columns")) goto fail;
        if (!chk(cudaMalloc(&D.band, (size_t)W * D.rows * 4), "cudaMalloc band")) goto fail;
        if (!upload_all(d)) goto fail;
    }

    // effect grids: if they no longer fit, switch that effect off rather than fail
    for (int d = 0; d < g_ndev; d++) {
        if (!alloc_smoke(d)) { g_sres = 0; for (int e = 0; e < g_ndev; e++) alloc_smoke(e); fx_dims(); break; }
    }
    for (int d = 0; d < g_ndev; d++) {
        if (!alloc_wave(d)) { g_wres = 0; for (int e = 0; e < g_ndev; e++) alloc_wave(e); fx_dims(); break; }
    }
    g_scur = 0; g_wcur = 0;

    if (g_cam.fogDist == 0.0f && g_cam.fog == 0) rc_params(9.0f, 0xFF0C0E12u, 1);
    rc_camera(1.5f, 1.5f, 0.0f);
    return 1;

fail:
    free_devices();
    return 0;
}

RC_API int rc_device_count(void) { return g_ndev; }

RC_API float rc_gpu_ms(int d) { return (d >= 0 && d < g_ndev) ? g_dev[d].kms : 0.0f; }

// VRAM in use on a GPU, in MB (everything on the card, not just this program)
RC_API float rc_vram_mb(int d)
{
    size_t fr = 0, to = 0;
    if (d < 0 || d >= g_ndev) return 0.0f;
    cudaSetDevice(d);
    if (cudaMemGetInfo(&fr, &to) != cudaSuccess) return 0.0f;
    return (float)((double)(to - fr) / 1048576.0);
}

// walls / floors / ceils: map width*height bytes each (NULL = leave unchanged)
RC_API void rc_set_map(const uint8_t *walls, const uint8_t *floors, const uint8_t *ceils)
{
    size_t n = (size_t)g_mw * g_mh;
    if (!g_walls) return;
    if (walls) memcpy(g_walls, walls, n);
    if (floors) memcpy(g_floors, floors, n);
    if (ceils) memcpy(g_ceils, ceils, n);
    for (int d = 0; d < g_ndev; d++) {
        cudaSetDevice(d);
        cudaMemcpy(g_dev[d].walls, g_walls, n, cudaMemcpyHostToDevice);
        cudaMemcpy(g_dev[d].floors, g_floors, n, cudaMemcpyHostToDevice);
        cudaMemcpy(g_dev[d].ceils, g_ceils, n, cudaMemcpyHostToDevice);
    }
}

// Change one wall cell (e.g. a wall that gets destroyed)
RC_API void rc_set_cell(int x, int y, int value)
{
    if (!g_walls || x < 0 || y < 0 || x >= g_mw || y >= g_mh) return;
    size_t i = (size_t)y * g_mw + x;
    g_walls[i] = (uint8_t)value;
    for (int d = 0; d < g_ndev; d++) {
        cudaSetDevice(d);
        cudaMemcpy(g_dev[d].walls + i, &g_walls[i], 1, cudaMemcpyHostToDevice);
    }
}

// 64x64 32-bit pixels (QB64 _MemImage of a 64x64 image)
RC_API void rc_set_texture(int id, const uint32_t *pixels)
{
    if (id < 0 || id >= MAXTEX || !pixels) return;
    uint32_t *dst = g_tex + (size_t)id * TEX * TEX;
    memcpy(dst, pixels, TEX * TEX * 4);
    for (int d = 0; d < g_ndev; d++) {
        cudaSetDevice(d);
        cudaMemcpy(g_dev[d].tex + (size_t)id * TEX * TEX, dst, TEX * TEX * 4, cudaMemcpyHostToDevice);
    }
}

// Door opening 0 = closed .. 1 = fully open
RC_API void rc_set_door(int x, int y, float open)
{
    if (!g_doors || x < 0 || y < 0 || x >= g_mw || y >= g_mh) return;
    size_t i = (size_t)y * g_mw + x;
    g_doors[i] = fminf(fmaxf(open, 0.0f), 1.0f);
    for (int d = 0; d < g_ndev; d++) {
        cudaSetDevice(d);
        cudaMemcpy(g_dev[d].doors + i, &g_doors[i], sizeof(float), cudaMemcpyHostToDevice);
    }
}

// Close every door (e.g. for a new level)
RC_API void rc_clear_doors(void)
{
    size_t n = (size_t)g_mw * g_mh;
    if (!g_doors) return;
    memset(g_doors, 0, n * sizeof(float));
    for (int d = 0; d < g_ndev; d++) {
        cudaSetDevice(d);
        cudaMemcpy(g_dev[d].doors, g_doors, n * sizeof(float), cudaMemcpyHostToDevice);
    }
}

// 4 floats per sprite: x, y, texture, scale (1 = wall height)
RC_API void rc_set_sprites(const float *data, int count)
{
    if (count < 0) count = 0;
    if (count > MAXSPR) count = MAXSPR;
    if (count > 0 && data) memcpy(g_sprites, data, (size_t)count * 4 * sizeof(float));
    g_nspr = count;
}

// ---- effects

// Smoke grid with res voxels per map cell across, and res voxels floor to
// ceiling. 0 = off. Every GPU holds two grids of (mw*res) x (mh*res) x res floats.
// Returns 0 (and leaves smoke off) if a GPU runs out of memory.
RC_API int rc_smoke_setup(int res)
{
    if (res < 0) res = 0;
    if (res > 32) res = 32;
    g_sres = res;
    fx_dims();
    g_scur = 0;
    for (int d = 0; d < g_ndev; d++) {
        if (!alloc_smoke(d)) {
            g_sres = 0;
            for (int e = 0; e < g_ndev; e++) alloc_smoke(e);
            fx_dims();
            return 0;
        }
    }
    return 1;
}

// A puff of smoke near the floor at map position (x, y); amount per second
RC_API void rc_smoke_add(float x, float y, float amount, float radius)
{
    if (g_sq.n >= MAXINJ) return;
    Inj &q = g_sq.v[g_sq.n++];
    q.x = x; q.y = y; q.amt = amount; q.r = radius;
}

// rise / swirl speeds in map cells per second, decay = fraction left after
// one second, sigma = how thick a unit of smoke looks, steps = ray-march samples
RC_API void rc_smoke_params(float rise, float swirl, float decay, float sigma, int steps)
{
    g_rise = rise;
    g_swirl = swirl;
    g_decay = fminf(fmaxf(decay, 0.0f), 1.0f);
    g_sigma = sigma;
    g_steps = (steps < 4) ? 4 : (steps > 256) ? 256 : steps;
}

// Ripple grid with res texels per map cell. 0 = off.
RC_API int rc_water_setup(int res)
{
    if (res < 0) res = 0;
    if (res > 64) res = 64;
    g_wres = res;
    fx_dims();
    g_wcur = 0;
    for (int d = 0; d < g_ndev; d++) {
        if (!alloc_wave(d)) {
            g_wres = 0;
            for (int e = 0; e < g_ndev; e++) alloc_wave(e);
            fx_dims();
            return 0;
        }
    }
    return 1;
}

// A drop (or a footstep) in the water at map position (x, y)
RC_API void rc_water_drop(float x, float y, float strength)
{
    if (g_wq.n >= MAXINJ) return;
    Inj &q = g_wq.v[g_wq.n++];
    q.x = x; q.y = y; q.amt = strength; q.r = 0.12f;
}

// rain = random drops per second near the player, damping = how long ripples last
RC_API void rc_water_params(float rainPerSec, float damping)
{
    g_rain = fmaxf(rainPerSec, 0.0f);
    g_damp = fminf(fmaxf(damping, 0.5f), 0.999f);
}

// Seconds since the last frame (drives the effect simulations)
RC_API void rc_tick(float dt)
{
    g_dt = fminf(fmaxf(dt, 0.001f), 0.1f);
    g_time += g_dt;
}

// Render one frame into W*H 32-bit pixels (QB64 _MemImage offset)
RC_API int rc_frame(uint32_t *pixels)
{
    if (g_ndev < 1 || !pixels) { snprintf(g_err, sizeof g_err, "not initialised"); return 0; }

    double t0 = now_ms();
    Cam c = g_cam;
    g_frame++;

    // project sprites on the CPU (tiny job), cull off-screen and far ones, nearest first
    int ns = 0;
    float invDet = 1.0f / (c.plx * c.dy - c.dx * c.ply);
    for (int i = 0; i < g_nspr; i++) {
        float sx = g_sprites[i * 4 + 0] - c.px;
        float sy = g_sprites[i * 4 + 1] - c.py;
        int st = (int)g_sprites[i * 4 + 2];
        float sc = g_sprites[i * 4 + 3];
        float tx = invDet * (c.dy * sx - c.dx * sy);
        float ty = invDet * (-c.ply * sx + c.plx * sy);
        if (ty < 0.15f || ty > 40.0f || st < 0 || st >= MAXTEX) continue;
        float base = c.H / ty;
        float scx = c.W * 0.5f * (1.0f + tx / ty), sw = base * sc;
        if (scx + sw * 0.5f < 0.0f || scx - sw * 0.5f > c.W) continue;
        SprP &s = g_sprP[ns++];
        s.sx = scx;
        s.h = sw;
        s.w = sw;
        s.top = c.H * 0.5f + base * 0.5f - s.h;   // standing on the floor
        s.depth = ty;
        s.tex = st;
    }
    qsort(g_sprP, ns, sizeof(SprP), cmp_depth);

    // effect inputs for this frame (same for every GPU)
    SmokeP sp;
    sp.t = g_time; sp.dt = g_dt; sp.rise = g_rise; sp.swirl = g_swirl;
    sp.windx = 0.05f; sp.windy = 0.03f;
    sp.decay = powf(g_decay, g_dt);
    sp.vx = g_svx; sp.vy = g_svy; sp.vz = g_svz; sp.res = g_sres;
    InjList sq = g_sq;
    g_sq.n = 0;

    int wsteps = 0;
    if (g_wres > 0) {
        g_wacc += g_dt;
        wsteps = (int)(g_wacc * 60.0f);
        g_wacc -= wsteps / 60.0f;
        if (wsteps > 4) { wsteps = 4; g_wacc = 0.0f; }
        // rain: random drops on water near the player
        float want = g_rain * g_dt;
        int nd = (int)want + ((rnd01() < want - (int)want) ? 1 : 0);
        for (int k = 0; k < nd && g_wq.n < MAXINJ; k++) {
            float rx = c.px + (rnd01() * 2.0f - 1.0f) * 12.0f;
            float ry = c.py + (rnd01() * 2.0f - 1.0f) * 12.0f;
            int cx = (int)floorf(rx), cy = (int)floorf(ry);
            if (cx < 0 || cy < 0 || cx >= g_mw || cy >= g_mh) continue;
            if (g_floors[cy * g_mw + cx] != WATER_ID) continue;
            rc_water_drop(rx, ry, 0.8f);
        }
    } else {
        g_wq.n = 0;
    }
    InjList wq = g_wq;
    g_wq.n = 0;
    InjList none;
    none.n = 0;

    int sNew = (g_sres > 0) ? 1 - g_scur : g_scur;
    int wNew = (wsteps % 2) ? 1 - g_wcur : g_wcur;

    for (int d = 0; d < g_ndev; d++) {
        Dev &D = g_dev[d];
        cudaSetDevice(d);
        if (ns > 0) cudaMemcpyAsync(D.spr, g_sprP, ns * sizeof(SprP), cudaMemcpyHostToDevice, D.st);
        cudaEventRecord(D.e0, D.st);

        if (g_sres > 0 && D.smoke[0]) {
            dim3 b(32, 8), g((g_svx + 31) / 32, (g_svy + 7) / 8);
            k_smoke_step<<<g, b, 0, D.st>>>(D.smoke[g_scur], D.smoke[1 - g_scur], D.walls, D.doors,
                                            g_mw, g_mh, sp, sq);
        }
        if (g_wres > 0 && D.wave[0]) {
            dim3 b(32, 8), g((g_wvx + 31) / 32, (g_wvy + 7) / 8);
            int wc = g_wcur;
            for (int s = 0; s < wsteps; s++) {
                k_wave<<<g, b, 0, D.st>>>(D.wave[wc], D.wave[1 - wc], g_wvx, g_wvy, g_wres,
                                          D.floors, g_mw, g_damp, (s == 0) ? wq : none);
                wc = 1 - wc;
            }
        }

        FxR fx;
        fx.vol = (g_sres > 0) ? D.smoke[sNew] : NULL;
        fx.vx = g_svx; fx.vy = g_svy; fx.vz = g_svz; fx.sres = g_sres;
        fx.steps = g_steps; fx.sigma = g_sigma;
        fx.wave = (g_wres > 0) ? D.wave[wNew] : NULL;
        fx.wvx = g_wvx; fx.wvy = g_wvy; fx.wres = g_wres;
        fx.frame = g_frame;

        k_columns<<<(c.W + 127) / 128, 128, 0, D.st>>>(c, D.walls, D.doors, g_mw, g_mh, D.cols);
        if (D.rows > 0) {
            dim3 bl(32, 8);
            dim3 gr((c.W + 31) / 32, (D.rows + 7) / 8);
            k_pixels<<<gr, bl, 0, D.st>>>(c, D.y0, D.rows, D.cols, D.floors, D.ceils, g_mw, g_mh,
                                          D.tex, D.spr, ns, fx, D.band);
        }
        cudaEventRecord(D.e1, D.st);
        if (!chk(cudaGetLastError(), "kernel launch")) return 0;
        if (D.rows > 0)
            cudaMemcpyAsync(g_stage + (size_t)D.y0 * c.W, D.band, (size_t)c.W * D.rows * 4,
                            cudaMemcpyDeviceToHost, D.st);
    }
    g_scur = sNew;
    g_wcur = wNew;

    for (int d = 0; d < g_ndev; d++) {
        Dev &D = g_dev[d];
        cudaSetDevice(d);
        if (!chk(cudaStreamSynchronize(D.st), "frame")) return 0;
        cudaEventElapsedTime(&D.kms, D.e0, D.e1);
    }
    double t1 = now_ms();

    memcpy(pixels, g_stage, (size_t)c.W * c.H * 4);
    double t2 = now_ms();

    g_gpuMs = (float)(t1 - t0);
    g_hostMs = (float)(t2 - t1);
    return 1;
}

RC_API void rc_stats(float *gpuMs, float *hostMs)
{
    *gpuMs = g_gpuMs;
    *hostMs = g_hostMs;
}

RC_API void rc_last_error(char *msg, int msglen)
{
    if (!msg || msglen <= 0) return;
    strncpy(msg, g_err, (size_t)msglen - 1);
    msg[msglen - 1] = 0;
}

} // extern "C"

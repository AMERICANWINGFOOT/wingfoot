// rcgpu.cu - multi-GPU Wolfenstein-style ray caster library for QB64-PE
//
// Each frame, every GPU:
//   1. casts one ray per screen column through the grid map (DDA), giving a
//      distance / texture / texture-x per column (cheap, every GPU does all)
//   2. draws its own horizontal band of the screen: textured walls, textured
//      floor and ceiling, sprites (depth-tested), distance fog
//   3. copies its band back into one pinned frame buffer
// The host then copies the finished frame into the QB64 screen image.
//
// Map cells (one byte each):
//   0        empty
//   1..63    solid wall, value = texture number
//   64..127  sliding door in the middle of the cell, texture = value - 64
// Floor and ceiling maps hold a texture number per cell (0 = none, shows fog).
// Textures are 64x64, 32-bit 0xAARRGGBB (QB64 image format); alpha < 128 is
// transparent on sprites.
//
// The library keeps its own host copy of the map, textures, doors and sprites,
// so rc_init can be called again (e.g. with a different GPU count) without
// re-sending anything.
//
// Build (CUDA 12.x, Maxwell sm_50):
//   nvcc -O2 -arch=sm_50 -Wno-deprecated-gpu-targets -Xcompiler -fPIC -shared -o librcgpu.so rcgpu.cu

#include <cuda_runtime.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include <time.h>
#include <stdint.h>

#define MAXDEV   8
#define TEX      64
#define MAXTEX   64
#define MAXSPR   512
#define MAXSTEPS 256

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

struct Dev {
    int y0, rows;           // this GPU's band of screen rows
    uint8_t *walls, *floors, *ceils;
    float *doors;
    uint32_t *tex;
    SprP *spr;
    ColHit *cols;
    uint32_t *band;
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
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000.0 + t.tv_nsec / 1.0e6;
}

// ---------------------------------------------------------------- device side

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
            // solid wall
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
            if (perp > next) continue;            // leaves the cell before the door
            float wx = (side == 0) ? c.py + perp * rdy : c.px + perp * rdx;
            wx -= floorf(wx);
            if (wx < open) continue;              // through the open gap
            h.dist = perp; h.texX = wx - open; h.tex = w - 64; h.side = side;
            break;
        }
    }
    cols[x] = h;
}

// Every pixel in this GPU's band
__global__ void k_pixels(Cam c, int y0, int rows, const ColHit *cols,
                         const uint8_t *floors, const uint8_t *ceils, int mw, int mh,
                         const uint32_t *tex, const SprP *spr, int nspr, uint32_t *band)
{
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int yy = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= c.W || yy >= rows) return;
    int y = y0 + yy;
    float yf = y + 0.5f;
    float halfH = c.H * 0.5f;

    ColHit h = cols[x];
    uint32_t out;
    float depth;

    float lineH = (h.tex >= 0) ? c.H / h.dist : 0.0f;
    float top = halfH - lineH * 0.5f, bot = halfH + lineH * 0.5f;

    if (h.tex >= 0 && yf >= top && yf < bot) {
        // wall
        int tx = min((int)(h.texX * TEX), TEX - 1);
        int ty = min(max((int)((yf - top) / lineH * TEX), 0), TEX - 1);
        uint32_t t = tex[h.tex * TEX * TEX + ty * TEX + tx];
        float k = (c.shade && h.side == 1) ? 0.72f : 1.0f;
        depth = h.dist;
        out = shade(t, k, fogf(c, depth), c.fog);
    } else {
        // floor (below the horizon) or ceiling (above)
        float camX = 2.0f * (x + 0.5f) / c.W - 1.0f;
        float rdx = c.dx + c.plx * camX, rdy = c.dy + c.ply * camX;
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
        if (ti <= 0 || ti >= MAXTEX) {
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
        break;
    }

    band[yy * c.W + x] = out;
}

// ---------------------------------------------------------------- host side

static int cmp_depth(const void *a, const void *b)
{
    float da = ((const SprP *)a)->depth, db = ((const SprP *)b)->depth;
    return (da < db) ? -1 : (da > db) ? 1 : 0;
}

static void free_devices(void)
{
    for (int d = 0; d < g_ndev; d++) {
        Dev &D = g_dev[d];
        cudaSetDevice(d);
        if (D.st) cudaStreamSynchronize(D.st);
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

void rc_shutdown(void)
{
    free_devices();
    free(g_walls); free(g_floors); free(g_ceils); free(g_doors);
    g_walls = g_floors = g_ceils = NULL;
    g_doors = NULL;
    g_mw = g_mh = 0;
}

// Relative share of screen rows for a GPU (call before rc_init). 1.0 = normal.
void rc_set_weight(int dev, float w)
{
    if (dev >= 0 && dev < MAXDEV) g_weight[dev] = w;
}

void rc_camera(float px, float py, float ang)
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

void rc_params(float fogDist, uint32_t fogColor, int shadeSides)
{
    g_cam.fogDist = fogDist;
    g_cam.fog = fogColor;
    g_cam.shade = shadeSides;
}

int rc_init(int maxdev, int W, int H, int mw, int mh)
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

    if (g_cam.fogDist == 0.0f && g_cam.fog == 0) rc_params(9.0f, 0xFF0C0E12u, 1);
    rc_camera(1.5f, 1.5f, 0.0f);
    return 1;

fail:
    free_devices();
    return 0;
}

int rc_device_count(void) { return g_ndev; }

float rc_gpu_ms(int d) { return (d >= 0 && d < g_ndev) ? g_dev[d].kms : 0.0f; }

// walls / floors / ceils: map width*height bytes each (NULL = leave unchanged)
void rc_set_map(const uint8_t *walls, const uint8_t *floors, const uint8_t *ceils)
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
void rc_set_cell(int x, int y, int value)
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
void rc_set_texture(int id, const uint32_t *pixels)
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
void rc_set_door(int x, int y, float open)
{
    if (!g_doors || x < 0 || y < 0 || x >= g_mw || y >= g_mh) return;
    size_t i = (size_t)y * g_mw + x;
    g_doors[i] = fminf(fmaxf(open, 0.0f), 1.0f);
    for (int d = 0; d < g_ndev; d++) {
        cudaSetDevice(d);
        cudaMemcpy(g_dev[d].doors + i, &g_doors[i], sizeof(float), cudaMemcpyHostToDevice);
    }
}

// 4 floats per sprite: x, y, texture, scale (1 = wall height)
void rc_set_sprites(const float *data, int count)
{
    if (count < 0) count = 0;
    if (count > MAXSPR) count = MAXSPR;
    if (count > 0 && data) memcpy(g_sprites, data, (size_t)count * 4 * sizeof(float));
    g_nspr = count;
}

// Render one frame into W*H 32-bit pixels (QB64 _MemImage offset)
int rc_frame(uint32_t *pixels)
{
    if (g_ndev < 1 || !pixels) { snprintf(g_err, sizeof g_err, "not initialised"); return 0; }

    double t0 = now_ms();
    Cam c = g_cam;

    // project sprites on the CPU (tiny job), nearest first
    int ns = 0;
    float invDet = 1.0f / (c.plx * c.dy - c.dx * c.ply);
    for (int i = 0; i < g_nspr; i++) {
        float sx = g_sprites[i * 4 + 0] - c.px;
        float sy = g_sprites[i * 4 + 1] - c.py;
        int st = (int)g_sprites[i * 4 + 2];
        float sc = g_sprites[i * 4 + 3];
        float tx = invDet * (c.dy * sx - c.dx * sy);
        float ty = invDet * (-c.ply * sx + c.plx * sy);
        if (ty < 0.15f || st < 0 || st >= MAXTEX) continue;
        float base = c.H / ty;
        SprP &s = g_sprP[ns++];
        s.sx = c.W * 0.5f * (1.0f + tx / ty);
        s.h = base * sc;
        s.w = base * sc;
        s.top = c.H * 0.5f + base * 0.5f - s.h;   // standing on the floor
        s.depth = ty;
        s.tex = st;
    }
    qsort(g_sprP, ns, sizeof(SprP), cmp_depth);

    for (int d = 0; d < g_ndev; d++) {
        Dev &D = g_dev[d];
        cudaSetDevice(d);
        if (ns > 0) cudaMemcpyAsync(D.spr, g_sprP, ns * sizeof(SprP), cudaMemcpyHostToDevice, D.st);
        cudaEventRecord(D.e0, D.st);
        k_columns<<<(c.W + 127) / 128, 128, 0, D.st>>>(c, D.walls, D.doors, g_mw, g_mh, D.cols);
        if (D.rows > 0) {
            dim3 bl(32, 8);
            dim3 gr((c.W + 31) / 32, (D.rows + 7) / 8);
            k_pixels<<<gr, bl, 0, D.st>>>(c, D.y0, D.rows, D.cols, D.floors, D.ceils, g_mw, g_mh,
                                          D.tex, D.spr, ns, D.band);
        }
        cudaEventRecord(D.e1, D.st);
        if (!chk(cudaGetLastError(), "kernel launch")) return 0;
        if (D.rows > 0)
            cudaMemcpyAsync(g_stage + (size_t)D.y0 * c.W, D.band, (size_t)c.W * D.rows * 4,
                            cudaMemcpyDeviceToHost, D.st);
    }

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

void rc_stats(float *gpuMs, float *hostMs)
{
    *gpuMs = g_gpuMs;
    *hostMs = g_hostMs;
}

void rc_last_error(char *msg, int msglen)
{
    if (!msg || msglen <= 0) return;
    strncpy(msg, g_err, (size_t)msglen - 1);
    msg[msglen - 1] = 0;
}

} // extern "C"

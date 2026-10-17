// idxgpu.cu - CUDA renderer for IndexView.bas
//
// One thread per star: project, draw the dot (atomicMax so the brighter
// star wins where dots overlap), and test for the mouse-hover star.
// One thread per quad edge: DDA line between two on-screen stars.
// The finished frame is copied straight into a QB64 _MemImage buffer.
//
// Build: ./build_idxgpu.sh

#include <cuda_runtime.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libidxgpu.h"

struct View {
    int mode, w, h, mx, my, hasMag;
    double cx, cy, cz, ex, ey, ez, nx, ny, nz, zoom, px, py, sky;
    float magLo, magHi;
};

static int       ready = 0;
static char      devName[256] = "";
static double   *d_x, *d_y, *d_z;
static float    *d_mag, *d_sx, *d_sy;
static uint8_t  *d_on;
static int       nStars = 0;
static int32_t  *d_quad;
static int       nQuads = 0, qDim = 0;
static uint32_t *d_fb;
static int       fbW = 0, fbH = 0;
static unsigned long long *d_pick;

#define GFREE(p) do { if (p) { cudaFree(p); p = 0; } } while (0)

// ----------------------------------------------------------------------
// device code
// ----------------------------------------------------------------------

// Same maths as Project% in IndexView.bas, but in buffer coordinates
// (no MAP_X0 offset). Gnomonic stays in double: at deep zoom the scale
// is up to 5e7 px/rad, which float cannot hold to a pixel.
__device__ __forceinline__ int projectPt(const View &v, double x, double y, double z,
                                         float &sx, float &sy)
{
    if (v.mode == 1) {
        double d = x * v.cx + y * v.cy + z * v.cz;
        if (d <= 0.01) return 0;
        double tx = (x * v.ex + y * v.ey + z * v.ez) / d;
        double ty = (x * v.nx + y * v.ny + z * v.nz) / d;
        double fx = v.w * 0.5 - (tx - v.px) * v.zoom;
        double fy = v.h * 0.5 - (ty - v.py) * v.zoom;
        if (fx < 0.0 || fx >= v.w || fy < 0.0 || fy >= v.h) return 0;
        sx = (float)fx; sy = (float)fy;
        return 1;
    }
    float fx = (float)x, fy = (float)y, fz = (float)z;
    float lon = atan2f(fy, fx);
    float lat = atan2f(fz, sqrtf(fx * fx + fy * fy));
    float cl  = cosf(lat);
    float den = sqrtf(1.0f + cl * cosf(lon * 0.5f));
    float hx  = 2.0f * 1.41421356f * cl * sinf(lon * 0.5f) / den;
    float hy  = 1.41421356f * sinf(lat) / den;
    sx = v.w * 0.5f - hx * (float)v.sky;
    sy = v.h * 0.5f - hy * (float)v.sky;
    if (sx < 0.0f || sx >= v.w || sy < 0.0f || sy >= v.h) return 0;
    return 1;
}

__global__ void kStars(View v, const double *x, const double *y, const double *z,
                       const float *mag, int n, float *osx, float *osy, uint8_t *on,
                       uint32_t *fb, unsigned long long *pick)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;

    float px = 0.0f, py = 0.0f;
    int ok = projectPt(v, x[i], y[i], z[i], px, py);
    on[i] = (uint8_t)ok;
    osx[i] = px; osy[i] = py;
    if (!ok) return;

    int r, lv;
    if (v.hasMag) {
        float t = (v.magHi - mag[i]) / (v.magHi - v.magLo);
        r  = (int)floorf(t * t * 2.4f + 0.15f);
        lv = 70 + (int)floorf(185.0f * t);
    } else {
        r = 1; lv = 220;
    }
    if (v.mode == 0 && r > 1) r = 1;
    if (r < 0) r = 0;
    if (r > 4) r = 4;
    if (lv < 0) lv = 0;
    if (lv > 255) lv = 255;
    int b = (int)(lv * 0.9f + 25.0f + 0.5f);
    if (b > 255) b = 255;
    uint32_t c = 0xFF000000u | ((uint32_t)lv << 16) | ((uint32_t)lv << 8) | (uint32_t)b;

    int cx = __float2int_rn(px), cy = __float2int_rn(py);
    for (int dy = -r; dy <= r; dy++) {
        int yy = cy + dy;
        if (yy < 0 || yy >= v.h) continue;
        int w = (int)floorf(sqrtf((float)(r * r - dy * dy)) + 0.5f);
        for (int dx = -w; dx <= w; dx++) {
            int xx = cx + dx;
            if (xx < 0 || xx >= v.w) continue;
            atomicMax(&fb[yy * v.w + xx], c);
        }
    }

    // hover: nearest star within 8 px; key = (distance bits, index)
    if (v.mx > -50000) {
        float ddx = px - (float)v.mx, ddy = py - (float)v.my;
        float d2 = ddx * ddx + ddy * ddy;
        if (d2 < 64.0f) {
            unsigned long long key = ((unsigned long long)__float_as_uint(d2) << 32) | (unsigned)i;
            atomicMin(pick, key);
        }
    }
}

__global__ void kQuads(int w, int h, const int32_t *quad, int nq, int dq, int qStep,
                       long long total, const float *sx, const float *sy,
                       const uint8_t *on, uint32_t *fb)
{
    long long t = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    if (t >= total) return;
    int pairs = dq * (dq - 1) / 2;
    int q = (int)(t / pairs) * qStep;
    int p = (int)(t % pairs);
    if (q >= nq) return;

    int a, b = 1;
    for (a = 0; a < dq - 1; a++) {
        int cnt = dq - 1 - a;
        if (p < cnt) { b = a + 1 + p; break; }
        p -= cnt;
    }
    int sa = quad[(long long)q * dq + a];
    int sb = quad[(long long)q * dq + b];
    if (sa <= 0 || sb <= 0) return;
    sa--; sb--;
    if (!on[sa] || !on[sb]) return;

    float x0 = sx[sa], y0 = sy[sa], x1 = sx[sb], y1 = sy[sb];
    if (fabsf(x0 - x1) >= w * 0.5f) return;   // wrap-around seam on all-sky

    const uint32_t c = 0xFF00C8E6u;            // _RGB32(0, 200, 230)
    int ix0 = __float2int_rn(x0), iy0 = __float2int_rn(y0);
    int ix1 = __float2int_rn(x1), iy1 = __float2int_rn(y1);
    int dx = ix1 - ix0, dy = iy1 - iy0;
    int n = max(abs(dx), abs(dy));
    for (int s = 0; s <= n; s++) {
        int xx = ix0, yy = iy0;
        if (n > 0) {
            xx = ix0 + __float2int_rn((float)dx * s / n);
            yy = iy0 + __float2int_rn((float)dy * s / n);
        }
        if (xx < 0 || xx >= w || yy < 0 || yy >= h) continue;
        fb[yy * w + xx] = c;
    }
}

// ----------------------------------------------------------------------
// host API
// ----------------------------------------------------------------------

static void freeStars(void)
{
    GFREE(d_x); GFREE(d_y); GFREE(d_z);
    GFREE(d_mag); GFREE(d_sx); GFREE(d_sy); GFREE(d_on);
    nStars = 0;
}

extern "C" int32_t idx_init(int32_t devWanted)
{
    int n = 0, best = -1;
    long long bestScore = -1;
    if (ready) return 1;
    if (cudaGetDeviceCount(&n) != cudaSuccess || n < 1) { cudaGetLastError(); return 0; }

    const char *env = getenv("IDXGPU_DEVICE");
    if (env && *env) devWanted = atoi(env);

    if (devWanted >= 0 && devWanted < n) {
        best = devWanted;
    } else {
        for (int i = 0; i < n; i++) {
            cudaDeviceProp p;
            if (cudaGetDeviceProperties(&p, i) != cudaSuccess) continue;
            long long score = (long long)p.multiProcessorCount * p.clockRate;
            if (score > bestScore) { bestScore = score; best = i; }
        }
    }
    if (best < 0) return 0;
    if (cudaSetDevice(best) != cudaSuccess) { cudaGetLastError(); return 0; }
    if (cudaFree(0) != cudaSuccess) { cudaGetLastError(); return 0; }
    if (cudaMalloc(&d_pick, sizeof(unsigned long long)) != cudaSuccess) { cudaGetLastError(); return 0; }

    cudaDeviceProp p;
    cudaGetDeviceProperties(&p, best);
    snprintf(devName, sizeof devName, "%s (dev %d, sm_%d%d)", p.name, best, p.major, p.minor);
    ready = 1;
    return 1;
}

extern "C" void idx_device_name(intptr_t buf, int32_t bufLen)
{
    if (!buf || bufLen < 1) return;
    strncpy((char *)buf, devName, (size_t)bufLen - 1);
    ((char *)buf)[bufLen - 1] = 0;
}

extern "C" int32_t idx_upload_stars(intptr_t px, intptr_t py, intptr_t pz, intptr_t pmag, int32_t n)
{
    if (!ready) return 0;
    freeStars();
    if (n <= 0 || !px || !py || !pz) return 1;

    size_t nd = (size_t)n * sizeof(double), nf = (size_t)n * sizeof(float);
    if (cudaMalloc(&d_x, nd) != cudaSuccess || cudaMalloc(&d_y, nd) != cudaSuccess ||
        cudaMalloc(&d_z, nd) != cudaSuccess || cudaMalloc(&d_mag, nf) != cudaSuccess ||
        cudaMalloc(&d_sx, nf) != cudaSuccess || cudaMalloc(&d_sy, nf) != cudaSuccess ||
        cudaMalloc(&d_on, (size_t)n) != cudaSuccess) {
        cudaGetLastError();
        freeStars();
        return 0;
    }
    cudaMemcpy(d_x, (const void *)px, nd, cudaMemcpyHostToDevice);
    cudaMemcpy(d_y, (const void *)py, nd, cudaMemcpyHostToDevice);
    cudaMemcpy(d_z, (const void *)pz, nd, cudaMemcpyHostToDevice);
    if (pmag) cudaMemcpy(d_mag, (const void *)pmag, nf, cudaMemcpyHostToDevice);
    else      cudaMemset(d_mag, 0, nf);
    if (cudaGetLastError() != cudaSuccess) { freeStars(); return 0; }
    nStars = n;
    return 1;
}

extern "C" int32_t idx_upload_quads(intptr_t pq, int32_t nQuad, int32_t dimQ)
{
    if (!ready) return 0;
    GFREE(d_quad);
    nQuads = 0; qDim = 0;
    if (nQuad <= 0 || dimQ < 2 || !pq) return 1;

    size_t bytes = (size_t)nQuad * dimQ * sizeof(int32_t);
    if (cudaMalloc(&d_quad, bytes) != cudaSuccess) { cudaGetLastError(); return 0; }
    cudaMemcpy(d_quad, (const void *)pq, bytes, cudaMemcpyHostToDevice);
    if (cudaGetLastError() != cudaSuccess) { GFREE(d_quad); return 0; }
    nQuads = nQuad; qDim = dimQ;
    return 1;
}

extern "C" int32_t idx_render(int32_t mode,
                              double cx, double cy, double cz,
                              double ex, double ey, double ez,
                              double nx, double ny, double nz,
                              double zoom, double panX, double panY, double sky,
                              int32_t w, int32_t h, int32_t mx, int32_t my,
                              int32_t hasMag, float magLo, float magHi,
                              int32_t quadsOn, int32_t quadStep, intptr_t fb)
{
    if (!ready || !fb || w < 1 || h < 1) return -1;

    if (w != fbW || h != fbH || !d_fb) {
        GFREE(d_fb);
        if (cudaMalloc(&d_fb, (size_t)w * h * 4) != cudaSuccess) {
            cudaGetLastError();
            fbW = fbH = 0;
            return -1;
        }
        fbW = w; fbH = h;
    }

    View v;
    v.mode = mode; v.w = w; v.h = h; v.mx = mx; v.my = my; v.hasMag = hasMag;
    v.cx = cx; v.cy = cy; v.cz = cz;
    v.ex = ex; v.ey = ey; v.ez = ez;
    v.nx = nx; v.ny = ny; v.nz = nz;
    v.zoom = zoom; v.px = panX; v.py = panY; v.sky = sky;
    v.magLo = magLo; v.magHi = magHi;

    size_t fbBytes = (size_t)w * h * 4;
    cudaMemset(d_fb, 0, fbBytes);                   // transparent
    cudaMemset(d_pick, 0xFF, sizeof(unsigned long long));

    if (nStars > 0) {
        kStars<<<(nStars + 255) / 256, 256>>>(v, d_x, d_y, d_z, d_mag, nStars,
                                               d_sx, d_sy, d_on, d_fb, d_pick);
        if (quadsOn && nQuads > 0 && qDim >= 2) {
            if (quadStep < 1) quadStep = 1;
            long long used  = ((long long)nQuads + quadStep - 1) / quadStep;
            long long total = used * (qDim * (qDim - 1) / 2);
            long long blocks = (total + 255) / 256;
            if (blocks > 0)
                kQuads<<<(unsigned)blocks, 256>>>(w, h, d_quad, nQuads, qDim, quadStep, total,
                                                   d_sx, d_sy, d_on, d_fb);
        }
    }

    unsigned long long key = ~0ull;
    cudaMemcpy((void *)fb, d_fb, fbBytes, cudaMemcpyDeviceToHost);
    cudaMemcpy(&key, d_pick, sizeof key, cudaMemcpyDeviceToHost);
    if (cudaGetLastError() != cudaSuccess) return -1;

    if (key == ~0ull) return 0;
    return (int32_t)(key & 0xFFFFFFFFull) + 1;
}

extern "C" void idx_shutdown(void)
{
    if (!ready) return;
    freeStars();
    GFREE(d_quad); GFREE(d_fb); GFREE(d_pick);
    nQuads = 0; qDim = 0; fbW = fbH = 0;
    ready = 0;
}

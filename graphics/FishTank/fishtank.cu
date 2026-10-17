// fishtank.cu  -  GPU aquarium renderer for QB64-PE
//
// QB64 runs the fish behaviour; this library shades every pixel of the tank.
//
// Build (CUDA, GTX 745 = sm_50, RTX 3050 = sm_86):
//   nvcc -O3 -shared -Xcompiler -fPIC -gencode arch=compute_50,code=sm_50
//        -gencode arch=compute_86,code=sm_86 -o libfishtank.so fishtank.cu
//   (one line; drop the sm_50 pair if your CUDA no longer supports Maxwell)
//
// Build (CPU fallback, no GPU needed - same picture, slower):
//   g++ -O3 -fopenmp -shared -fPIC -x c++ -o libfishtank.so fishtank.cu
//
// Data layouts (all float / QB64 Single):
//   fish : 8 per fish  x, y, face(-1..1), rot(rad), size(px), hue(0..1), phase, z(0 near..1 far)
//   bub  : 3 per bubble x, y, r
//   food : 2 per flake  x, y
// Fish should arrive sorted far-to-near (painter's order).
// Output: W*H 32-bit pixels, memory order B,G,R,A (QB64 32-bit image layout).

#include <stdint.h>
#include <math.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#ifdef __CUDACC__
  #include <cuda_runtime.h>
  #define HD __host__ __device__ __forceinline__
#else
  #define HD static inline
#endif

#define FT_FISH_STRIDE 8
#define FT_BUB_STRIDE  3
#define FT_FOOD_STRIDE 2
#define FT_MAX_FISH    64
#define FT_MAX_BUB     512
#define FT_MAX_FOOD    128
#define FT_N_WEED      11
#define FT_N_ROCK      4

// ---------------------------------------------------------------- helpers
typedef struct { float r, g, b; } V3;

HD V3 v3(float r, float g, float b) { V3 v; v.r = r; v.g = g; v.b = b; return v; }
HD V3 add3(V3 a, V3 b) { return v3(a.r + b.r, a.g + b.g, a.b + b.b); }
HD V3 mul3(V3 a, float k) { return v3(a.r * k, a.g * k, a.b * k); }
HD V3 mix3(V3 a, V3 b, float t) { return v3(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t); }
HD float clampf(float x, float a, float b) { return x < a ? a : (x > b ? b : x); }
HD float smoothf(float e0, float e1, float x) { float t = clampf((x - e0) / (e1 - e0), 0.f, 1.f); return t * t * (3.f - 2.f * t); }
HD float fractf(float x) { return x - floorf(x); }
HD float hash1(float n) { return fractf(sinf(n * 12.9898f) * 43758.5453f); }
HD float hash2(float x, float y) { return fractf(sinf(x * 127.1f + y * 311.7f) * 43758.5453f); }

HD V3 hsv(float h, float s, float v) {
    h = fractf(h) * 6.f;
    float c = v * s;
    float x = c * (1.f - fabsf(fmodf(h, 2.f) - 1.f));
    float m = v - c;
    V3 o;
    if      (h < 1.f) o = v3(c, x, 0);
    else if (h < 2.f) o = v3(x, c, 0);
    else if (h < 3.f) o = v3(0, c, x);
    else if (h < 4.f) o = v3(0, x, c);
    else if (h < 5.f) o = v3(x, 0, c);
    else              o = v3(c, 0, x);
    return add3(o, v3(m, m, m));
}

// ---------------------------------------------------------------- scenery
HD float sandTop(float x, float H) {
    return H * 0.84f + sinf(x * 0.004f) * H * 0.025f + sinf(x * 0.011f + 1.3f) * H * 0.012f;
}

HD float caustic(float x, float y, float t) {
    float xx = x * 0.018f, yy = y * 0.018f, c = 0.f;
    c += sinf(xx * 1.0f + sinf(yy * 1.3f + t * 0.6f) + t * 0.40f);
    c += sinf(yy * 1.7f + sinf(xx * 1.9f - t * 0.8f) - t * 0.35f);
    c += sinf((xx + yy) * 1.2f + sinf(xx * 0.7f + t * 0.5f) + t * 0.25f);
    c = 1.f - fabsf(sinf(c * 1.3f));
    return c * c * c * c * c * c;
}

HD V3 waterColor(float px, float py, float W, float H, float s, float t) {
    float v = py / H;
    V3 shallow = v3(0.06f, 0.38f, 0.56f);
    V3 deep    = v3(0.01f, 0.07f, 0.17f);
    V3 col = mix3(shallow, deep, powf(clampf(v, 0.f, 1.f), 0.8f));

    // slanted light shafts
    float a = px / s + py / s * 0.38f;
    float r1 = 0.5f + 0.5f * sinf(a * 0.011f + t * 0.13f);
    float r2 = 0.5f + 0.5f * sinf(a * 0.029f - t * 0.21f + 1.7f);
    float ray = r1 * r2; ray = ray * ray * ray;
    col = add3(col, mul3(v3(0.55f, 0.75f, 0.80f), ray * 0.16f * (1.f - v)));

    // caustics shimmering near the surface
    col = add3(col, mul3(v3(0.6f, 0.85f, 0.9f), caustic(px / s, py / s, t) * 0.10f * (1.f - v) * (1.f - v)));
    return col;
}

HD V3 drawSand(V3 col, float px, float py, float W, float H, float s, float t, V3 water) {
    float top = sandTop(px, H);
    if (py < top - 1.5f) return col;
    float depth = (py - top) / (H - top + 1.f);
    float grain = hash2(floorf(px), floorf(py)) * 0.10f;
    V3 sand = mul3(v3(0.78f, 0.67f, 0.46f), 0.75f + grain - depth * 0.25f);

    // pebbles: one maybe per 16px cell
    float cell = 16.f * s;
    float cx = floorf(px / cell), cy = floorf(py / cell);
    float hp = hash2(cx, cy);
    if (hp > 0.72f) {
        float ox = (cx + 0.3f + 0.4f * hash2(cy, cx)) * cell;
        float oy = (cy + 0.3f + 0.4f * hash2(cx + 7.f, cy)) * cell;
        float rr = cell * (0.18f + 0.18f * hash1(hp * 91.f));
        float d = sqrtf((px - ox) * (px - ox) + (py - oy) * (py - oy) * 1.6f);
        if (d < rr && oy > top + 3.f) {
            V3 peb = hsv(0.06f + hash1(hp * 13.f) * 0.08f, 0.25f, 0.45f + 0.35f * hash1(hp * 7.f));
            peb = mul3(peb, 0.75f + 0.35f * (1.f - d / rr));
            sand = mix3(sand, peb, smoothf(rr, rr - 1.5f, d));
        }
    }
    // light ripples on the bottom
    sand = add3(sand, mul3(v3(0.5f, 0.6f, 0.5f), caustic(px / s * 1.4f, py / s * 2.2f, t * 1.1f) * 0.22f));
    sand = mix3(sand, water, 0.30f);
    return mix3(col, sand, smoothf(top - 1.5f, top + 1.5f, py));
}

HD V3 drawRocks(V3 col, float px, float py, float W, float H, float s, V3 water) {
    for (int i = 0; i < FT_N_ROCK; i++) {
        float cx = W * (0.12f + 0.25f * i + 0.08f * hash1(i * 3.1f));
        float rx = (50.f + 45.f * hash1(i * 5.7f)) * s;
        float ry = rx * (0.55f + 0.2f * hash1(i * 9.3f));
        float cy = sandTop(cx, H) + ry * 0.35f;
        float dx = (px - cx) / rx, dy = (py - cy) / ry;
        // lumpy outline
        float ang = atan2f(dy, dx);
        float lump = 1.f + 0.08f * sinf(ang * 3.f + i) + 0.05f * sinf(ang * 7.f + i * 2.f);
        float e = sqrtf(dx * dx + dy * dy) / lump;
        if (e < 1.f && py < sandTop(px, H) + ry * 0.2f) {
            float light = 0.45f + 0.55f * clampf(-dy * 0.8f + 0.3f - dx * 0.2f, 0.f, 1.f);
            float tex = 0.85f + 0.15f * hash2(floorf(px / (3.f * s)), floorf(py / (3.f * s)));
            V3 rock = mul3(hsv(0.58f + 0.05f * i, 0.12f, 0.55f), light * tex);
            rock = mix3(rock, water, 0.25f);
            float edge = (1.f - e) * fminf(rx, ry);
            col = mix3(col, rock, clampf(edge, 0.f, 1.f));
        }
    }
    return col;
}

HD V3 drawWeed(V3 col, float px, float py, float W, float H, float s, float t, V3 water, int backLayer) {
    for (int i = 0; i < FT_N_WEED; i++) {
        int isBack = (i % 3) == 0;
        if (isBack != backLayer) continue;
        float bx = W * (0.04f + 0.92f * hash1(i * 17.3f + 2.f));
        float base = sandTop(bx, H) + 6.f * s;
        float height = H * (0.22f + 0.30f * hash1(i * 4.1f));
        float topY = base - height;
        if (py < topY - 2.f || py > base) continue;
        float f = (base - py) / height;
        float sway = sinf(t * 0.8f + i * 1.7f + f * 2.6f) * f * f * 34.f * s
                   + sinf(t * 1.9f + i + f * 6.f) * f * 4.f * s;
        float cx = bx + sway;
        float w = (8.f - 5.5f * f) * s * (0.85f + 0.25f * sinf(f * 24.f + i));
        float d = fabsf(px - cx);
        if (d < w + 1.f) {
            float shade = 0.55f + 0.45f * (1.f - d / w);
            V3 g = mul3(hsv(0.27f + 0.08f * hash1(i * 2.3f), 0.70f, 0.55f + 0.2f * f), shade);
            g = add3(g, mul3(v3(0.2f, 0.3f, 0.1f), 0.15f * sinf(py * 0.25f)));
            if (isBack) g = mix3(g, water, 0.55f);
            col = mix3(col, g, smoothf(w + 1.f, w - 0.5f, d));
        }
    }
    return col;
}

// ---------------------------------------------------------------- fish
HD V3 drawFish(V3 col, float px, float py, const float* F, float s, V3 water) {
    float fx = F[0], fy = F[1], face = F[2], rot = F[3];
    float size = F[4], hue = F[5], phase = F[6], z = F[7];
    float sz = size * s * (1.f - 0.35f * z);
    float dx = px - fx, dy = py - fy;
    if (fabsf(dx) > sz * 0.8f || fabsf(dy) > sz * 0.8f) return col;

    float cr = cosf(rot), sr = sinf(rot);
    float lx = dx * cr + dy * sr;
    float ly = -dx * sr + dy * cr;
    float fc = (fabsf(face) < 0.12f) ? (face < 0.f ? -0.12f : 0.12f) : face;
    float X = lx / fc / sz;
    float Y = ly / sz;
    // tail wag, stronger toward the back
    Y -= sinf(phase - X * 4.f) * 0.055f * clampf(0.45f - X, 0.f, 1.2f);

    float px1 = 1.f / (sz * fabsf(fc));     // ~ one pixel in local X units
    int pattern = (int)(hash1(hue * 97.f) * 3.f);
    V3 base = hsv(hue, 0.78f, 0.95f);
    V3 finc = hsv(hue + 0.03f, 0.55f, 0.90f);
    float alpha = 0.f;
    V3 c = base;

    // tail (forked)
    if (X < -0.33f && X > -0.66f) {
        float th = 0.04f + (-0.33f - X) * 1.05f;
        float notch = fmaxf(0.f, (-0.52f - X) * 1.1f);
        float ay = fabsf(Y);
        if (ay < th && ay >= notch) {
            float streak = 0.80f + 0.20f * sinf(Y * 70.f);
            c = mul3(finc, streak);
            alpha = 0.85f * smoothf(th, th - 0.02f, ay);
        }
    }
    // dorsal fin
    {
        float ys = 0.18f * sqrtf(fmaxf(0.f, 1.f - (X / 0.43f) * (X / 0.43f)));
        float fw = 0.20f;
        float xf = X + 0.02f;
        if (fabsf(xf) < fw) {
            float topY = -ys - 0.13f * (1.f - fabsf(xf) / fw) * (1.f - 0.4f * (xf / fw));
            if (Y < -ys * 0.8f && Y > topY) {
                c = mul3(finc, 0.85f + 0.15f * sinf(X * 80.f));
                alpha = 0.85f;
            }
        }
        // small belly fin
        float xb = X + 0.05f;
        if (fabsf(xb) < 0.09f) {
            float botY = ys + 0.07f * (1.f - fabsf(xb) / 0.09f);
            if (Y > ys * 0.8f && Y < botY) { c = mul3(finc, 0.9f); alpha = 0.8f; }
        }
    }
    // body
    float bh = 0.18f + 0.03f * X;
    float e = (X / 0.43f) * (X / 0.43f) + (Y / bh) * (Y / bh);
    if (e < 1.f) {
        float shade = 0.62f + 0.48f * clampf(Y / bh * 0.5f + 0.5f, 0.f, 1.f);
        V3 b = mul3(base, shade);
        if (pattern == 1) {
            // white bands, clownfish-ish
            float band = fabsf(sinf((X + 0.05f) * 11.f));
            if (band < 0.22f) b = mix3(b, v3(0.95f, 0.95f, 0.95f), 0.9f);
        } else if (pattern == 2) {
            // dark spots
            float sp = hash2(floorf(X * 14.f), floorf(Y * 14.f));
            float cxs = (floorf(X * 14.f) + 0.5f) / 14.f, cys = (floorf(Y * 14.f) + 0.5f) / 14.f;
            float ds = sqrtf((X - cxs) * (X - cxs) + (Y - cys) * (Y - cys));
            if (sp > 0.6f && ds < 0.025f) b = mul3(b, 0.35f);
        }
        // belly highlight and scale shimmer
        b = add3(b, mul3(v3(1, 1, 1), 0.10f * smoothf(0.3f, 1.f, Y / bh)));
        b = add3(b, mul3(v3(1, 1, 1), 0.025f * sinf(X * 60.f + phase) * sinf(Y * 60.f)));
        float edgeDist = (1.f - sqrtf(e)) * 0.17f;   // in local units
        float a = clampf(edgeDist / px1 + 0.3f, 0.f, 1.f);
        c = mix3(c, b, alpha > 0.f ? a : 1.f);
        alpha = fmaxf(alpha, a);

        // pectoral fin, flapping
        float pfx = X - 0.10f, pfy = Y - 0.05f;
        float flap = 0.75f + 0.25f * sinf(phase * 1.7f);
        float pe = (pfx / 0.09f) * (pfx / 0.09f) + (pfy / (0.035f * flap)) * (pfy / (0.035f * flap));
        if (pe < 1.f) c = mix3(c, mul3(finc, 1.1f), 0.5f);

        // gill line
        if (fabsf(X - 0.20f + Y * Y * 3.f) < 0.008f && fabsf(Y) < bh * 0.7f) c = mul3(c, 0.75f);

        // eye
        float ex = X - 0.29f, ey = Y + 0.035f;
        float ed = sqrtf(ex * ex + ey * ey);
        if (ed < 0.045f) {
            V3 eye = v3(0.95f, 0.95f, 0.9f);
            if (ed < 0.027f) eye = v3(0.02f, 0.02f, 0.03f);
            float hx = ex + 0.010f, hy = ey + 0.010f;
            if (sqrtf(hx * hx + hy * hy) < 0.009f) eye = v3(1, 1, 1);
            c = mix3(c, eye, smoothf(0.045f, 0.045f - px1, ed));
        }
    }
    if (alpha <= 0.f) return col;
    c = mix3(c, water, z * 0.55f);   // depth haze
    return mix3(col, c, alpha);
}

// ---------------------------------------------------------------- bubbles / food
HD V3 drawBubble(V3 col, float px, float py, const float* B) {
    float r = B[2];
    float dx = px - B[0], dy = py - B[1];
    if (fabsf(dx) > r + 2.f || fabsf(dy) > r + 2.f) return col;
    float d = sqrtf(dx * dx + dy * dy);
    if (d > r + 1.f) return col;
    float ring = smoothf(r - 2.0f, r - 0.3f, d) * smoothf(r + 1.f, r, d);
    col = add3(col, mul3(v3(0.75f, 0.9f, 1.f), 0.06f));
    col = mix3(col, v3(0.85f, 0.95f, 1.f), ring * 0.65f);
    float hx = dx + r * 0.35f, hy = dy + r * 0.35f;
    float hd = sqrtf(hx * hx + hy * hy);
    col = mix3(col, v3(1, 1, 1), smoothf(r * 0.28f, r * 0.10f, hd) * 0.85f);
    return col;
}

HD V3 drawFood(V3 col, float px, float py, const float* Fd, float s) {
    float r = 4.5f * s;
    float dx = px - Fd[0], dy = py - Fd[1];
    if (fabsf(dx) > r + 1.f || fabsf(dy) > r + 1.f) return col;
    float d = sqrtf(dx * dx + dy * dy * 1.6f);
    V3 f = mul3(v3(0.78f, 0.45f, 0.18f), 0.8f + 0.3f * (1.f - d / r));
    return mix3(col, f, smoothf(r, r - 1.f, d));
}

// ---------------------------------------------------------------- per-pixel
HD uint32_t shadePixel(int ix, int iy, int W, int H, float t,
                       const float* fish, int nf, const float* bub, int nb,
                       const float* food, int nfd) {
    float px = (float)ix + 0.5f, py = (float)iy + 0.5f;
    float fW = (float)W, fH = (float)H;
    float s = fH / 720.f;

    V3 water = waterColor(px, py, fW, fH, s, t);
    V3 col = water;
    col = drawWeed(col, px, py, fW, fH, s, t, water, 1);
    col = drawSand(col, px, py, fW, fH, s, t, water);
    col = drawRocks(col, px, py, fW, fH, s, water);
    col = drawWeed(col, px, py, fW, fH, s, t, water, 0);
    for (int i = 0; i < nfd; i++) col = drawFood(col, px, py, food + i * FT_FOOD_STRIDE, s);
    for (int i = 0; i < nf;  i++) col = drawFish(col, px, py, fish + i * FT_FISH_STRIDE, s, water);
    for (int i = 0; i < nb;  i++) col = drawBubble(col, px, py, bub + i * FT_BUB_STRIDE);

    // wavy surface line at the top
    float surf = fH * 0.025f + sinf(px * 0.018f + t * 1.4f) * 2.5f * s + sinf(px * 0.047f - t * 2.1f) * 1.2f * s;
    if (py < surf + 2.f) {
        float a = smoothf(surf + 2.f, surf - 1.f, py);
        col = mix3(col, v3(0.55f, 0.82f, 0.92f), a * 0.6f);
        if (fabsf(py - surf) < 1.2f) col = add3(col, v3(0.25f, 0.3f, 0.3f));
    }
    // vignette / glass
    float u = px / fW - 0.5f, v = py / fH - 0.5f;
    col = mul3(col, 1.f - 0.55f * (u * u + v * v));

    int R = (int)(clampf(col.r, 0.f, 1.f) * 255.f + 0.5f);
    int G = (int)(clampf(col.g, 0.f, 1.f) * 255.f + 0.5f);
    int Bc = (int)(clampf(col.b, 0.f, 1.f) * 255.f + 0.5f);
    return 0xFF000000u | ((uint32_t)R << 16) | ((uint32_t)G << 8) | (uint32_t)Bc;
}

// ---------------------------------------------------------------- state
static int g_W = 0, g_H = 0;
static char g_err[256] = "";
static char g_dev[128] = "";

static int clampCount(int n, int mx) { return n < 0 ? 0 : (n > mx ? mx : n); }

#ifdef __CUDACC__
static uint32_t* d_out = 0;
static float *d_fish = 0, *d_bub = 0, *d_food = 0;

__global__ void k_render(uint32_t* out, int W, int H, float t,
                         const float* fish, int nf, const float* bub, int nb,
                         const float* food, int nfd) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= W || y >= H) return;
    out[y * W + x] = shadePixel(x, y, W, H, t, fish, nf, bub, nb, food, nfd);
}

static int cudaFail(cudaError_t e, const char* where) {
    if (e == cudaSuccess) return 0;
    snprintf(g_err, sizeof(g_err), "%s: %s", where, cudaGetErrorString(e));
    return 1;
}
#endif

extern "C" {

void ft_shutdown(void) {
#ifdef __CUDACC__
    if (d_out)  cudaFree(d_out);
    if (d_fish) cudaFree(d_fish);
    if (d_bub)  cudaFree(d_bub);
    if (d_food) cudaFree(d_food);
    d_out = 0; d_fish = d_bub = d_food = 0;
#endif
    g_W = g_H = 0;
}

int ft_init(int w, int h) {
    ft_shutdown();
    if (w <= 0 || h <= 0) { snprintf(g_err, sizeof(g_err), "bad size %dx%d", w, h); return 0; }
#ifdef __CUDACC__
    int dev = 0;
    cudaDeviceProp p;
    if (cudaFail(cudaGetDevice(&dev), "cudaGetDevice")) return 0;
    if (cudaFail(cudaGetDeviceProperties(&p, dev), "cudaGetDeviceProperties")) return 0;
    snprintf(g_dev, sizeof(g_dev), "%s (CUDA sm_%d%d)", p.name, p.major, p.minor);
    if (cudaFail(cudaMalloc((void**)&d_out, (size_t)w * h * 4), "cudaMalloc out")) return 0;
    if (cudaFail(cudaMalloc((void**)&d_fish, FT_MAX_FISH * FT_FISH_STRIDE * sizeof(float)), "cudaMalloc fish")) return 0;
    if (cudaFail(cudaMalloc((void**)&d_bub,  FT_MAX_BUB  * FT_BUB_STRIDE  * sizeof(float)), "cudaMalloc bub")) return 0;
    if (cudaFail(cudaMalloc((void**)&d_food, FT_MAX_FOOD * FT_FOOD_STRIDE * sizeof(float)), "cudaMalloc food")) return 0;
#else
    snprintf(g_dev, sizeof(g_dev), "CPU fallback");
#endif
    g_W = w; g_H = h;
    g_err[0] = 0;
    return 1;
}

int ft_render(float t, const float* fish, int nf, const float* bub, int nb,
              const float* food, int nfd, void* outBGRA) {
    if (!g_W || !outBGRA) { snprintf(g_err, sizeof(g_err), "not initialised"); return 0; }
    nf  = clampCount(nf,  FT_MAX_FISH);
    nb  = clampCount(nb,  FT_MAX_BUB);
    nfd = clampCount(nfd, FT_MAX_FOOD);
#ifdef __CUDACC__
    if (nf  && cudaFail(cudaMemcpy(d_fish, fish, nf  * FT_FISH_STRIDE * sizeof(float), cudaMemcpyHostToDevice), "copy fish")) return 0;
    if (nb  && cudaFail(cudaMemcpy(d_bub,  bub,  nb  * FT_BUB_STRIDE  * sizeof(float), cudaMemcpyHostToDevice), "copy bub")) return 0;
    if (nfd && cudaFail(cudaMemcpy(d_food, food, nfd * FT_FOOD_STRIDE * sizeof(float), cudaMemcpyHostToDevice), "copy food")) return 0;
    dim3 blk(16, 16);
    dim3 grd((g_W + 15) / 16, (g_H + 15) / 16);
    k_render<<<grd, blk>>>(d_out, g_W, g_H, t, d_fish, nf, d_bub, nb, d_food, nfd);
    if (cudaFail(cudaGetLastError(), "kernel launch")) return 0;
    if (cudaFail(cudaMemcpy(outBGRA, d_out, (size_t)g_W * g_H * 4, cudaMemcpyDeviceToHost), "copy frame")) return 0;
#else
    uint32_t* out = (uint32_t*)outBGRA;
    #pragma omp parallel for schedule(dynamic, 4)
    for (int y = 0; y < g_H; y++)
        for (int x = 0; x < g_W; x++)
            out[y * g_W + x] = shadePixel(x, y, g_W, g_H, t, fish, nf, bub, nb, food, nfd);
#endif
    return 1;
}

// Copies a NUL-terminated message into a QB64 fixed-length string buffer.
void ft_last_error(char* buf, int n) { if (buf && n > 0) { strncpy(buf, g_err, n - 1); buf[n - 1] = 0; } }
void ft_device_name(char* buf, int n) { if (buf && n > 0) { strncpy(buf, g_dev, n - 1); buf[n - 1] = 0; } }
float ft_sand_top(float x, int h) { return sandTop(x, (float)h); }

} // extern "C"

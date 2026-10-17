/*
 * qbgpu.cu  -  CUDA helpers for QBCap
 *
 * Built as its own library (libqbgpu.so) and loaded at run time by
 * libqbcap.so when you press "Initialise GPU". If it is missing, or there
 * is no NVIDIA card / driver, QBCap uses the identical CPU code instead.
 *
 * Build (one file runs on the GTX 745s, the GTX 1070 and the RTX 3050):
 *   sh build_gpu.sh
 *
 * Sharpness score (must match score_cpu() in qbcap.c):
 *   L(x,y)  = sum of the 2x2 pixel block at superpixel (x,y)   (Bayer-safe)
 *   lap     = 4*L(x,y) - L(x-1,y) - L(x+1,y) - L(x,y-1) - L(x,y+1)
 *   score   = 1000 * mean(lap^2) / mean(L)^2      over all inner superpixels
 */
#include <cuda_runtime.h>
#include <stdio.h>
#include <string.h>

#define BLOCK      256
#define MAX_BLOCKS 1024

static int     g_dev = -1;
static void   *d_frame = NULL;
static size_t  d_cap = 0;
static float  *d_part = NULL;
static float   h_part[2 * MAX_BLOCKS];
static char    lastErr[256];

static int cuda_fail(cudaError_t e, const char *where)
{
    snprintf(lastErr, sizeof lastErr, "%s: %s", where, cudaGetErrorString(e));
    return -1;
}

extern "C" const char *qbg_error(void) { return lastErr; }

extern "C" int qbg_device_count(void)
{
    int n = 0;
    cudaError_t e = cudaGetDeviceCount(&n);
    if (e != cudaSuccess) { cuda_fail(e, "cudaGetDeviceCount"); return 0; }
    return n;
}

extern "C" int qbg_init(int dev, char *name, int len, int *memMB, int *ccMajor, int *ccMinor)
{
    cudaDeviceProp p;
    cudaError_t e;
    int n = qbg_device_count();
    if (n <= 0) return -1;
    if (dev < 0 || dev >= n) {
        snprintf(lastErr, sizeof lastErr, "CUDA device %d does not exist (%d found)", dev, n);
        return -1;
    }
    e = cudaSetDevice(dev);
    if (e != cudaSuccess) return cuda_fail(e, "cudaSetDevice");
    e = cudaGetDeviceProperties(&p, dev);
    if (e != cudaSuccess) return cuda_fail(e, "cudaGetDeviceProperties");
    if (name && len > 0) { strncpy(name, p.name, len - 1); name[len - 1] = 0; }
    *memMB = (int)(p.totalGlobalMem >> 20);
    *ccMajor = p.major;
    *ccMinor = p.minor;
    e = cudaMalloc((void **)&d_part, sizeof(float) * 2 * MAX_BLOCKS);
    if (e != cudaSuccess) return cuda_fail(e, "cudaMalloc(partials)");
    g_dev = dev;
    return 0;
}

extern "C" void qbg_shutdown(void)
{
    if (g_dev < 0) return;
    cudaSetDevice(g_dev);
    if (d_frame) cudaFree(d_frame);
    if (d_part) cudaFree(d_part);
    d_frame = NULL; d_part = NULL; d_cap = 0;
    g_dev = -1;
}

/* 2x2 superpixel sum, always in the 16-bit domain (8-bit data scaled x256) */
__device__ __forceinline__ float sp(const void *f, int w, int x, int y, int b16)
{
    size_t i = (size_t)(2 * y) * w + 2 * x;
    if (b16) {
        const unsigned short *p = (const unsigned short *)f;
        return (float)p[i] + (float)p[i + 1] + (float)p[i + w] + (float)p[i + w + 1];
    } else {
        const unsigned char *p = (const unsigned char *)f;
        return ((float)p[i] + (float)p[i + 1] + (float)p[i + w] + (float)p[i + w + 1]) * 256.0f;
    }
}

__global__ void k_score(const void *frame, int w, int h, int b16, float *part)
{
    __shared__ float sL[BLOCK];
    __shared__ float sE[BLOCK];
    int W2 = w / 2, H2 = h / 2;
    int iw = W2 - 2;
    long long nInner = (long long)(W2 - 2) * (H2 - 2);
    float accL = 0.0f, accE = 0.0f;
    long long k;
    int t = threadIdx.x, s;

    for (k = (long long)blockIdx.x * blockDim.x + t; k < nInner; k += (long long)gridDim.x * blockDim.x) {
        int x = 1 + (int)(k % iw);
        int y = 1 + (int)(k / iw);
        float c = sp(frame, w, x, y, b16);
        float lap = 4.0f * c - sp(frame, w, x - 1, y, b16) - sp(frame, w, x + 1, y, b16)
                             - sp(frame, w, x, y - 1, b16) - sp(frame, w, x, y + 1, b16);
        accL += c;
        accE += lap * lap;
    }
    sL[t] = accL;
    sE[t] = accE;
    __syncthreads();
    for (s = BLOCK / 2; s > 0; s >>= 1) {
        if (t < s) { sL[t] += sL[t + s]; sE[t] += sE[t + s]; }
        __syncthreads();
    }
    if (t == 0) { part[2 * blockIdx.x] = sL[0]; part[2 * blockIdx.x + 1] = sE[0]; }
}

/* returns the sums so the caller can form the score exactly like the CPU path */
extern "C" int qbg_score(const void *frame, int w, int h, int b16,
                         double *sumL, double *sumE, long long *count)
{
    size_t bytes = (size_t)w * h * (b16 ? 2 : 1);
    long long nInner;
    int blocks, i;
    cudaError_t e;
    double L = 0, E = 0;

    if (g_dev < 0) { snprintf(lastErr, sizeof lastErr, "GPU not initialised"); return -1; }
    if (w < 6 || h < 6) { snprintf(lastErr, sizeof lastErr, "frame too small"); return -1; }
    cudaSetDevice(g_dev);                       /* the current device is per host thread */
    if (bytes > d_cap) {
        if (d_frame) cudaFree(d_frame);
        e = cudaMalloc(&d_frame, bytes);
        if (e != cudaSuccess) { d_frame = NULL; d_cap = 0; return cuda_fail(e, "cudaMalloc(frame)"); }
        d_cap = bytes;
    }
    e = cudaMemcpy(d_frame, frame, bytes, cudaMemcpyHostToDevice);
    if (e != cudaSuccess) return cuda_fail(e, "cudaMemcpy(frame)");

    nInner = (long long)(w / 2 - 2) * (h / 2 - 2);
    blocks = (int)((nInner + BLOCK - 1) / BLOCK);
    if (blocks > MAX_BLOCKS) blocks = MAX_BLOCKS;
    k_score<<<blocks, BLOCK>>>(d_frame, w, h, b16, d_part);
    e = cudaGetLastError();
    if (e != cudaSuccess) return cuda_fail(e, "k_score launch");
    e = cudaMemcpy(h_part, d_part, sizeof(float) * 2 * blocks, cudaMemcpyDeviceToHost);
    if (e != cudaSuccess) return cuda_fail(e, "cudaMemcpy(partials)");
    for (i = 0; i < blocks; i++) { L += h_part[2 * i]; E += h_part[2 * i + 1]; }
    *sumL = L; *sumE = E; *count = nInner;
    return 0;
}

/* ------------------------------------------------------------------ */
/* live stacking: warp each new frame onto the reference and add it   */
/* (must match cpu_accumulate() in qbcap.c)                           */
/* ------------------------------------------------------------------ */
static float          *d_in[3], *d_mean[3], *d_m2[3];
static unsigned short *d_cnt[3];
static int            *d_rej = NULL;
static int             sP = 0, sW = 0, sH = 0;

extern "C" void qbg_stack_free(void)
{
    int p;
    if (g_dev >= 0) cudaSetDevice(g_dev);
    for (p = 0; p < 3; p++) {
        if (d_in[p]) cudaFree(d_in[p]);
        if (d_mean[p]) cudaFree(d_mean[p]);
        if (d_m2[p]) cudaFree(d_m2[p]);
        if (d_cnt[p]) cudaFree(d_cnt[p]);
        d_in[p] = d_mean[p] = d_m2[p] = NULL; d_cnt[p] = NULL;
    }
    if (d_rej) cudaFree(d_rej);
    d_rej = NULL; sP = sW = sH = 0;
}

/* allocate (or clear) the stack on the GPU */
extern "C" int qbg_stack_alloc(int P, int W, int H)
{
    size_t n = (size_t)W * H;
    int p;
    cudaError_t e;
    if (g_dev < 0) { snprintf(lastErr, sizeof lastErr, "GPU not initialised"); return -1; }
    cudaSetDevice(g_dev);
    if (P != sP || W != sW || H != sH) {
        qbg_stack_free();
        for (p = 0; p < P; p++) {
            if ((e = cudaMalloc((void **)&d_in[p], n * sizeof(float))) != cudaSuccess ||
                (e = cudaMalloc((void **)&d_mean[p], n * sizeof(float))) != cudaSuccess ||
                (e = cudaMalloc((void **)&d_m2[p], n * sizeof(float))) != cudaSuccess ||
                (e = cudaMalloc((void **)&d_cnt[p], n * sizeof(unsigned short))) != cudaSuccess) {
                qbg_stack_free();
                return cuda_fail(e, "cudaMalloc(stack)");
            }
        }
        if ((e = cudaMalloc((void **)&d_rej, sizeof(int))) != cudaSuccess) { qbg_stack_free(); return cuda_fail(e, "cudaMalloc(rej)"); }
        sP = P; sW = W; sH = H;
    }
    for (p = 0; p < P; p++) {
        cudaMemset(d_mean[p], 0, n * sizeof(float));
        cudaMemset(d_m2[p], 0, n * sizeof(float));
        cudaMemset(d_cnt[p], 0, n * sizeof(unsigned short));
    }
    e = cudaGetLastError();
    if (e != cudaSuccess) return cuda_fail(e, "cudaMemset(stack)");
    return 0;
}

__global__ void k_stack_add(const float *src, float *mean, float *m2, unsigned short *cnt,
                            int W, int H, float a, float b, float tx, float ty,
                            int mode, float kappa, int *rej)
{
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    float u, v, fx, fy, s, mu, d;
    int x0, y0;
    size_t i;
    unsigned n;
    if (x >= W || y >= H) return;
    u = __fsub_rn(__fmul_rn(a, (float)x), __fmul_rn(b, (float)y)) + tx;
    v = __fadd_rn(__fmul_rn(b, (float)x), __fmul_rn(a, (float)y)) + ty;
    if (u < 0.0f || v < 0.0f || u > W - 1.001f || v > H - 1.001f) return;
    x0 = (int)u; y0 = (int)v; fx = u - x0; fy = v - y0;
    {
        const float *q = src + (size_t)y0 * W + x0;
        s = __fadd_rn(__fmul_rn(__fadd_rn(__fmul_rn(q[0], 1 - fx), __fmul_rn(q[1], fx)), 1 - fy),
                      __fmul_rn(__fadd_rn(__fmul_rn(q[W], 1 - fx), __fmul_rn(q[W + 1], fx)), fy));
    }
    i = (size_t)y * W + x;
    n = cnt[i];
    mu = mean[i];
    if (mode == 1 && n >= 5) {
        float sd = sqrtf(m2[i] / (float)(n - 1));
        if (fabsf(s - mu) > __fadd_rn(__fmul_rn(kappa, sd), 1.0f)) { atomicAdd(rej, 1); return; }
    }
    if (n >= 65535) return;
    n++;
    d = s - mu;
    mu = __fadd_rn(mu, __fdiv_rn(d, (float)n));
    m2[i] = __fadd_rn(m2[i], __fmul_rn(d, s - mu));
    mean[i] = mu;
    cnt[i] = (unsigned short)n;
}

/* add one calibrated frame (P host planes of W x H floats) using the transform cur = R*ref + t */
extern "C" int qbg_stack_add(float *const *in, float a, float b, float tx, float ty,
                             int mode, float kappa, int *rejected)
{
    size_t n = (size_t)sW * sH;
    int p, zero = 0;
    dim3 blk(32, 8), grd((sW + 31) / 32, (sH + 7) / 8);
    cudaError_t e;
    if (sP == 0) { snprintf(lastErr, sizeof lastErr, "GPU stack not allocated"); return -1; }
    cudaSetDevice(g_dev);
    cudaMemcpy(d_rej, &zero, sizeof(int), cudaMemcpyHostToDevice);
    for (p = 0; p < sP; p++) {
        e = cudaMemcpy(d_in[p], in[p], n * sizeof(float), cudaMemcpyHostToDevice);
        if (e != cudaSuccess) return cuda_fail(e, "cudaMemcpy(stack frame)");
        k_stack_add<<<grd, blk>>>(d_in[p], d_mean[p], d_m2[p], d_cnt[p], sW, sH, a, b, tx, ty, mode, kappa, d_rej);
        e = cudaGetLastError();
        if (e != cudaSuccess) return cuda_fail(e, "k_stack_add launch");
    }
    e = cudaMemcpy(rejected, d_rej, sizeof(int), cudaMemcpyDeviceToHost);
    if (e != cudaSuccess) return cuda_fail(e, "cudaMemcpy(rejected)");
    return 0;
}

/* copy the whole stack state back (mean, variance sums, counts) */
extern "C" int qbg_stack_fetch(float **mean, float **m2, unsigned short **cnt)
{
    size_t n = (size_t)sW * sH;
    int p;
    cudaError_t e;
    if (sP == 0) { snprintf(lastErr, sizeof lastErr, "GPU stack not allocated"); return -1; }
    cudaSetDevice(g_dev);
    for (p = 0; p < sP; p++) {
        if ((e = cudaMemcpy(mean[p], d_mean[p], n * sizeof(float), cudaMemcpyDeviceToHost)) != cudaSuccess ||
            (e = cudaMemcpy(m2[p], d_m2[p], n * sizeof(float), cudaMemcpyDeviceToHost)) != cudaSuccess ||
            (e = cudaMemcpy(cnt[p], d_cnt[p], n * sizeof(unsigned short), cudaMemcpyDeviceToHost)) != cudaSuccess)
            return cuda_fail(e, "cudaMemcpy(stack fetch)");
    }
    return 0;
}

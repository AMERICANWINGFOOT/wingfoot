// g3d.cu - GPU3D: pixel-based 3D shapes for QB64-PE, CUDA back end for NVIDIA cards  (v1.1)
//
// The idea: place 3D shapes the same way QB64 places a CIRCLE - by screen pixel.
//   x, y      screen pixels (the shape's centre)
//   z         depth into the screen, in pixels. At z = 0 a shape is drawn at
//             exactly its pixel size; larger z shrinks it with perspective,
//             negative z brings it toward you.
//   w, h, d   size in pixels (width, height, depth)
//   ax,ay,az  rotation in degrees about the shape's own centre (X, then Y, then Z)
//   color     0xAARRGGBB, like _RGB32
//
// Every pixel is ray-traced on the GPUs: each pixel's ray is rotated into each
// shape's own frame and hit exactly, so shapes sort and intersect correctly with
// no triangles and no z-buffer. Each GPU draws its own band of rows.
//
// Shapes: 0 box, 1 sphere/ellipsoid, 2 cylinder, 3 cone, 4 pyramid, 5 diamond
// Style flags: 1 wire, 2 outline, 4 shiny, 8 flat (no lighting), 16 hide back wires
// Textures: 128x128 32-bit (QB64 image layout), ids 1..63, 0 = none.
//
// Needs g3d_math.h and g3d_common.h in the same folder (shared with the Vulkan
// back end, g3d_vk.cpp, which exports the same functions for AMD and Intel cards).
//
// Build on Linux (CUDA 12.x; Maxwell sm_50 plus PTX for any newer NVIDIA card):
//   nvcc -O2 -Wno-deprecated-gpu-targets -gencode arch=compute_50,code=sm_50 -gencode arch=compute_50,code=compute_50 -Xcompiler -fPIC -shared -o libg3d.so g3d.cu
//
// Build on Windows (x64 Native Tools Command Prompt for VS, CUDA 12.x):
//   nvcc -O2 -Wno-deprecated-gpu-targets -gencode arch=compute_50,code=sm_50 -gencode arch=compute_50,code=compute_50 -shared -o g3d.dll g3d.cu

#include <cuda_runtime.h>
#include "g3d_common.h"

// ---------------------------------------------------------------- GPU side

__global__ void k_draw(View v, int y0, int rows, const Obj *objs, int nobj, const uint32_t *tex, uint32_t *band)
{
    __shared__ Obj sh[G3_CHUNK];
    int lid = threadIdx.y * blockDim.x + threadIdx.x;
    int nthr = blockDim.x * blockDim.y;
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int yy = blockIdx.y * blockDim.y + threadIdx.y;
    bool live = (x < v.W && yy < rows);
    float px = (float)x, py = (float)(y0 + yy);
    int ns = v.aa;

    float bt[G3_MAXAA];
    int bi[G3_MAXAA], bs[G3_MAXAA];
    for (int s = 0; s < ns; s++) { bt[s] = 1e30f; bi[s] = -1; bs[s] = 0; }

    for (int baseI = 0; baseI < nobj; baseI += G3_CHUNK) {
        int cnt = min(G3_CHUNK, nobj - baseI);
        __syncthreads();
        for (int i = lid; i < cnt; i += nthr) sh[i] = objs[baseI + i];
        __syncthreads();
        if (!live) continue;
        for (int k = 0; k < cnt; k++) {
            const Obj &o = sh[k];
            if (px + 1.0f < o.x0 || px > o.x1 || py + 1.0f < o.y0 || py > o.y1) continue;
            for (int s = 0; s < ns; s++) {
                float ox, oy, t;
                int side;
                V3 O, D;
                aa_offset(ns, s, ox, oy);
                make_ray(v, px + ox, py + oy, O, D);
                if (obj_hit(o, v, O, D, t, side) && t < bt[s]) { bt[s] = t; bi[s] = baseI + k; bs[s] = side; }
            }
        }
    }
    if (!live) return;

    V3 acc = v3(0, 0, 0);
    int hits = 0;
    for (int s = 0; s < ns; s++) {
        if (bi[s] < 0) continue;
        float ox, oy;
        V3 O, D;
        aa_offset(ns, s, ox, oy);
        make_ray(v, px + ox, py + oy, O, D);
        acc = vadd(acc, shade_hit(objs[bi[s]], v, tex, O, D, bt[s], bs[s]));
        hits++;
    }
    uint32_t out;
    if (v.fill) {
        V3 bg = unpack(v.bg);
        float cov = (float)hits / ns;
        V3 c = vadd(vmul(acc, 1.0f / ns), vmul(bg, 1.0f - cov));
        out = pack(c, 1.0f);
    } else if (hits > 0) {
        out = pack(vmul(acc, 1.0f / hits), (float)hits / ns);
    } else {
        out = 0;
    }
    band[(size_t)yy * v.W + x] = out;
}

// ---------------------------------------------------------------- host side

struct Dev {
    int y0, rows;
    Obj *objs;
    uint32_t *tex;
    uint32_t *band;
    cudaStream_t st;
    cudaEvent_t e0, e1;
    float kms;
};

static Dev g_dev[G3_MAXDEV];
static float g_weight[G3_MAXDEV];
static int g_ndev = 0;
static uint32_t *g_stage = NULL;        // pinned full frame
static Obj *g_list = NULL;              // pinned list of the shapes on screen

static int chk(cudaError_t e, const char *where)
{
    if (e != cudaSuccess) {
        snprintf(g_err, sizeof g_err, "%s: %s", where, cudaGetErrorString(e));
        return 0;
    }
    return 1;
}

static void free_devices(void)
{
    for (int d = 0; d < g_ndev; d++) {
        Dev &D = g_dev[d];
        cudaSetDevice(d);
        if (D.st) cudaStreamSynchronize(D.st);
        if (D.objs) cudaFree(D.objs);
        if (D.tex) cudaFree(D.tex);
        if (D.band) cudaFree(D.band);
        if (D.e0) cudaEventDestroy(D.e0);
        if (D.e1) cudaEventDestroy(D.e1);
        if (D.st) cudaStreamDestroy(D.st);
        memset(&D, 0, sizeof D);
    }
    if (g_ndev > 0) cudaSetDevice(0);
    if (g_stage) { cudaFreeHost(g_stage); g_stage = NULL; }
    if (g_list) { cudaFreeHost(g_list); g_list = NULL; }
    g_ndev = 0;
}

extern "C" {

G3_API void g3_shutdown(void)
{
    free_devices();
}

// Relative share of screen rows for a GPU (call before g3_init). 1.0 = normal.
G3_API void g3_set_weight(int dev, float w)
{
    if (dev >= 0 && dev < G3_MAXDEV) g_weight[dev] = w;
}

// Start on up to maxdev GPUs (0 = all) for a W x H image. Textures survive a
// re-init; the view settings are reset only when the size changes.
G3_API int g3_init(int maxdev, int W, int H)
{
    int count = 0, y = 0;
    float w[G3_MAXDEV], wsum = 0.0f;

    free_devices();
    if (!chk(cudaGetDeviceCount(&count), "cudaGetDeviceCount")) return 0;
    if (count < 1) { snprintf(g_err, sizeof g_err, "no CUDA devices"); return 0; }
    if (W < 16 || H < 16) { snprintf(g_err, sizeof g_err, "bad size"); return 0; }
    if (maxdev < 1 || maxdev > count) maxdev = count;
    if (maxdev > G3_MAXDEV) maxdev = G3_MAXDEV;
    if (maxdev > H / 8) maxdev = H / 8;
    if (W != g_view.W || H != g_view.H) view_defaults(W, H);

    for (int d = 0; d < maxdev; d++) {
        w[d] = (g_weight[d] > 0.0f) ? g_weight[d] : 1.0f;
        wsum += w[d];
    }

    cudaSetDevice(0);
    if (!chk(cudaHostAlloc((void **)&g_stage, (size_t)W * H * 4, cudaHostAllocPortable), "cudaHostAlloc frame")) goto fail;
    if (!chk(cudaHostAlloc((void **)&g_list, G3_MAXOBJ * sizeof(Obj), cudaHostAllocPortable), "cudaHostAlloc shapes")) goto fail;

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
        if (!chk(cudaMalloc(&D.objs, G3_MAXOBJ * sizeof(Obj)), "cudaMalloc shapes")) goto fail;
        if (!chk(cudaMalloc(&D.tex, sizeof g_tex), "cudaMalloc textures")) goto fail;
        if (!chk(cudaMalloc(&D.band, (size_t)W * (D.rows > 0 ? D.rows : 1) * 4), "cudaMalloc band")) goto fail;
        if (!chk(cudaMemcpy(D.tex, g_tex, sizeof g_tex, cudaMemcpyHostToDevice), "upload textures")) goto fail;
    }
    return 1;

fail:
    free_devices();
    return 0;
}

G3_API int g3_device_count(void) { return g_ndev; }

G3_API float g3_gpu_ms(int d) { return (d >= 0 && d < g_ndev) ? g_dev[d].kms : 0.0f; }

// VRAM in use on a GPU, in MB (everything on the card, not just this program)
G3_API float g3_vram_mb(int d)
{
    size_t fr = 0, to = 0;
    if (d < 0 || d >= g_ndev) return 0.0f;
    cudaSetDevice(d);
    if (cudaMemGetInfo(&fr, &to) != cudaSuccess) return 0.0f;
    return (float)((double)(to - fr) / 1048576.0);
}

// Accepted so programs work with either back end; CUDA uses every NVIDIA card it finds
G3_API void g3_prefer_device(const char *name)
{
    (void)name;
}

// Name of a GPU in use, e.g. "CUDA: NVIDIA GeForce GTX 745"
G3_API void g3_device_name(int d, char *msg, int msglen)
{
    cudaDeviceProp p;
    if (!msg || msglen <= 0) return;
    msg[0] = 0;
    if (d < 0 || d >= g_ndev) return;
    if (cudaGetDeviceProperties(&p, d) != cudaSuccess) return;
    snprintf(msg, (size_t)msglen, "CUDA: %s", p.name);
}

// 128x128 32-bit pixels (QB64 _MemImage of a 128x128 image)
G3_API void g3_set_texture(int id, const uint32_t *pixels)
{
    uint32_t *src = tex_store(id, pixels);
    if (!src) return;
    for (int d = 0; d < g_ndev; d++) {
        cudaSetDevice(d);
        cudaMemcpy(g_dev[d].tex + (size_t)id * G3_TEX * G3_TEX, src, G3_TEX * G3_TEX * 4, cudaMemcpyHostToDevice);
    }
}

// Draw the queued shapes into W*H 32-bit pixels (QB64 _MemImage offset).
// mode 0: draw over what is already in the image (edges blend smoothly)
// mode 1: fill the whole image with bg first (faster: no blending on the CPU)
G3_API int g3_draw(uint32_t *pixels, int mode, uint32_t bg)
{
    if (g_ndev < 1 || !pixels) { snprintf(g_err, sizeof g_err, "not initialised"); return 0; }
    double t0 = now_ms();
    View v = g_view;
    v.fill = (mode == 1);
    v.bg = bg | 0xFF000000u;
    size_t npix = (size_t)v.W * v.H;

    int n = cull_list(v, g_list);
    if (n == 0) {
        if (v.fill) {
            for (size_t i = 0; i < npix; i++) pixels[i] = v.bg;
        }
        g_gpuMs = 0;
        g_hostMs = (float)(now_ms() - t0);
        for (int d = 0; d < g_ndev; d++) g_dev[d].kms = 0;
        return 1;
    }

    for (int d = 0; d < g_ndev; d++) {
        Dev &D = g_dev[d];
        if (D.rows <= 0) continue;
        cudaSetDevice(d);
        cudaMemcpyAsync(D.objs, g_list, n * sizeof(Obj), cudaMemcpyHostToDevice, D.st);
        cudaEventRecord(D.e0, D.st);
        dim3 bl(32, 8);
        dim3 gr((v.W + 31) / 32, (D.rows + 7) / 8);
        k_draw<<<gr, bl, 0, D.st>>>(v, D.y0, D.rows, D.objs, n, D.tex, D.band);
        cudaEventRecord(D.e1, D.st);
        if (!chk(cudaGetLastError(), "kernel launch")) return 0;
        cudaMemcpyAsync(g_stage + (size_t)D.y0 * v.W, D.band, (size_t)v.W * D.rows * 4,
                        cudaMemcpyDeviceToHost, D.st);
    }
    for (int d = 0; d < g_ndev; d++) {
        Dev &D = g_dev[d];
        if (D.rows <= 0) continue;
        cudaSetDevice(d);
        if (!chk(cudaStreamSynchronize(D.st), "frame")) return 0;
        cudaEventElapsedTime(&D.kms, D.e0, D.e1);
    }
    double t1 = now_ms();
    composite(pixels, g_stage, npix, v.fill);
    double t2 = now_ms();
    g_gpuMs = (float)(t1 - t0);
    g_hostMs = (float)(t2 - t1);
    return 1;
}

} // extern "C"

// gpuzip.cu - multi-GPU chunked LZ compressor for QB64-PE (libgpuzip.so)
//
// Format: every chunk (<= 64 KB) is an independent standard LZ4 block.
// GPU side: one warp per chunk. The warp tests 32 positions at once against a
// shared-memory hash table, takes the earliest match (greedy), emits the LZ4
// sequence, then moves on. Many chunks run at once, and chunk groups are pulled
// from a shared queue by every GPU (and optionally CPU threads), so a faster
// card simply takes more of the work.
//
// Build: see build.sh

#include <cuda_runtime.h>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <string>
#include <thread>
#include <atomic>
#include <mutex>
#include <algorithm>
#include <ftw.h>
#include <sys/stat.h>
#include <errno.h>
#include "gpuzip.h"

// ---------------------------------------------------------------- constants
#define HT_BITS        12
#define HT_SIZE        (1 << HT_BITS)
#define HT_EMPTY       0xFFFF
#define MINMATCH       4
#define LASTLITERALS   5
#define MFLIMIT        12
#define MAX_CHUNK      65536
#define WARPS_PER_BLK  4
#define GROUP_CHUNKS   64      // queue unit (4 MB at 64 KB chunks)
#define GPU_GROUPS     4       // a GPU grabs 4 groups (256 chunks) per launch
#define GPU_SLOT_CHUNKS (GROUP_CHUNKS * GPU_GROUPS)

static inline __host__ __device__ int lz4Bound(int n) { return n + n / 255 + 16; }

static inline __host__ __device__ uint32_t rd32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static inline __host__ __device__ uint32_t hash4(uint32_t v)
{
    return (v * 2654435761u) >> (32 - HT_BITS);
}

// ---------------------------------------------------------------- error text
static std::mutex  g_errLock;
static std::string g_err;
static void setErr(const std::string &s)
{
    std::lock_guard<std::mutex> lk(g_errLock);
    if (g_err.empty()) g_err = s;
}

// ================================================================ GPU kernel
// Writes one LZ4 sequence. Every lane runs the same arithmetic so they all agree
// on 'op'; lane 0 writes the header bytes, all lanes copy literals together.
__device__ int warpEmit(int lane, uint8_t *dst, int op, const uint8_t *src,
                        int anchor, int litLen, int offset, int mlen, bool hasMatch)
{
    int ml = hasMatch ? (mlen - MINMATCH) : 0;
    uint8_t token = (uint8_t)(((litLen >= 15 ? 15 : litLen) << 4) | (ml >= 15 ? 15 : ml));
    if (lane == 0) dst[op] = token;
    op++;
    if (litLen >= 15) {
        int r = litLen - 15;
        while (r >= 255) { if (lane == 0) dst[op] = 255; op++; r -= 255; }
        if (lane == 0) dst[op] = (uint8_t)r;
        op++;
    }
    for (int i = lane; i < litLen; i += 32) dst[op + i] = src[anchor + i];
    op += litLen;
    if (hasMatch) {
        if (lane == 0) { dst[op] = (uint8_t)(offset & 255); dst[op + 1] = (uint8_t)(offset >> 8); }
        op += 2;
        if (ml >= 15) {
            int r = ml - 15;
            while (r >= 255) { if (lane == 0) dst[op] = 255; op++; r -= 255; }
            if (lane == 0) dst[op] = (uint8_t)r;
            op++;
        }
    }
    return op;
}

__global__ void lzKernel(const uint8_t *__restrict__ in, int totalLen, int chunkSize, int nChunks,
                         uint8_t *out, int outStride, int32_t *outSizes)
{
    __shared__ uint16_t ht[WARPS_PER_BLK][HT_SIZE];
    const unsigned FULL = 0xffffffffu;
    int warp  = threadIdx.x >> 5;
    int lane  = threadIdx.x & 31;
    int chunk = blockIdx.x * WARPS_PER_BLK + warp;
    if (chunk >= nChunks) return;              // whole warp leaves together

    const uint8_t *src = in + (size_t)chunk * chunkSize;
    int n = totalLen - chunk * chunkSize;
    if (n > chunkSize) n = chunkSize;
    uint8_t  *dst = out + (size_t)chunk * outStride;
    uint16_t *h   = ht[warp];

    for (int i = lane; i < HT_SIZE; i += 32) h[i] = HT_EMPTY;
    __syncwarp();

    int op = 0, anchor = 0, p = 0;
    int mflimit    = n - MFLIMIT;              // a match may start only below this
    int matchlimit = n - LASTLITERALS;         // and must end at or below this

    if (n > MFLIMIT) {
        while (p < mflimit) {
            int pos = p + lane;
            int len = 0, cand = 0;
            if (pos < mflimit) {
                uint32_t v = rd32(src + pos);
                int c = h[hash4(v)];
                if (c != HT_EMPTY && c < pos && rd32(src + c) == v) {
                    int l = MINMATCH, maxl = matchlimit - pos;
                    while (l < maxl && src[c + l] == src[pos + l]) l++;
                    len = l; cand = c;
                }
            }
            unsigned m = __ballot_sync(FULL, len >= MINMATCH);
            int f = m ? (__ffs(m) - 1) : 32;
            __syncwarp();
            // remember the positions we are about to pass over
            if (lane < f && pos < mflimit) h[hash4(rd32(src + pos))] = (uint16_t)pos;
            __syncwarp();
            if (f == 32) { p += 32; continue; }

            int mlen = __shfl_sync(FULL, len, f);
            int mc   = __shfl_sync(FULL, cand, f);
            int mpos = p + f;
            op = warpEmit(lane, dst, op, src, anchor, mpos - anchor, mpos - mc, mlen, true);
            for (int q = mpos + lane; q < mpos + mlen && q < mflimit; q += 32)
                h[hash4(rd32(src + q))] = (uint16_t)q;
            p = mpos + mlen;
            anchor = p;
            __syncwarp();
        }
    }
    op = warpEmit(lane, dst, op, src, anchor, n - anchor, 0, 0, false);
    if (lane == 0) outSizes[chunk] = op;
}

// ================================================================ CPU codec
static int cpuEmit(uint8_t *dst, int op, const uint8_t *src, int anchor, int litLen,
                   int offset, int mlen, bool hasMatch)
{
    int ml = hasMatch ? (mlen - MINMATCH) : 0;
    dst[op++] = (uint8_t)(((litLen >= 15 ? 15 : litLen) << 4) | (ml >= 15 ? 15 : ml));
    if (litLen >= 15) {
        int r = litLen - 15;
        while (r >= 255) { dst[op++] = 255; r -= 255; }
        dst[op++] = (uint8_t)r;
    }
    memcpy(dst + op, src + anchor, litLen);
    op += litLen;
    if (hasMatch) {
        dst[op++] = (uint8_t)(offset & 255);
        dst[op++] = (uint8_t)(offset >> 8);
        if (ml >= 15) {
            int r = ml - 15;
            while (r >= 255) { dst[op++] = 255; r -= 255; }
            dst[op++] = (uint8_t)r;
        }
    }
    return op;
}

// Plain greedy LZ4 with the same hash table size as the GPU kernel.
static int cpuCompressChunk(const uint8_t *src, int n, uint8_t *dst)
{
    int ht[HT_SIZE];
    for (int i = 0; i < HT_SIZE; i++) ht[i] = -1;
    int op = 0, anchor = 0, p = 0;
    int mflimit = n - MFLIMIT, matchlimit = n - LASTLITERALS;
    if (n > MFLIMIT) {
        while (p < mflimit) {
            uint32_t v = rd32(src + p);
            uint32_t hh = hash4(v);
            int c = ht[hh];
            ht[hh] = p;
            if (c >= 0 && rd32(src + c) == v) {
                int l = MINMATCH, maxl = matchlimit - p;
                while (l < maxl && src[c + l] == src[p + l]) l++;
                op = cpuEmit(dst, op, src, anchor, p - anchor, p - c, l, true);
                for (int q = p + 1; q < p + l && q < mflimit; q++) ht[hash4(rd32(src + q))] = q;
                p += l;
                anchor = p;
            } else {
                p++;
            }
        }
    }
    return cpuEmit(dst, op, src, anchor, n - anchor, 0, 0, false);
}

// Bounds-checked LZ4 block decoder. Returns bytes produced or -1.
static int lz4Decode(const uint8_t *src, int srcLen, uint8_t *dst, int dstLen)
{
    int ip = 0, op = 0;
    for (;;) {
        if (ip >= srcLen) return -1;
        int token = src[ip++];
        int lit = token >> 4;
        if (lit == 15) {
            int b;
            do { if (ip >= srcLen) return -1; b = src[ip++]; lit += b; } while (b == 255);
        }
        if (lit > srcLen - ip || lit > dstLen - op) return -1;
        memcpy(dst + op, src + ip, lit);
        ip += lit; op += lit;
        if (ip == srcLen) break;                 // last sequence has no match
        if (ip + 2 > srcLen) return -1;
        int off = src[ip] | (src[ip + 1] << 8);
        ip += 2;
        if (off == 0 || off > op) return -1;
        int ml = token & 15;
        if (ml == 15) {
            int b;
            do { if (ip >= srcLen) return -1; b = src[ip++]; ml += b; } while (b == 255);
        }
        ml += MINMATCH;
        if (ml > dstLen - op) return -1;
        uint8_t *d = dst + op;
        const uint8_t *s = d - off;
        if (off >= ml) memcpy(d, s, ml);
        else for (int i = 0; i < ml; i++) d[i] = s[i];
        op += ml;
    }
    return op;
}

// ================================================================ CRC32 (slice-by-8)
static uint32_t g_crcT[8][256];
static std::once_flag g_crcOnce;
static void crcInit()
{
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        g_crcT[0][i] = c;
    }
    for (int t = 1; t < 8; t++)
        for (int i = 0; i < 256; i++)
            g_crcT[t][i] = (g_crcT[t - 1][i] >> 8) ^ g_crcT[0][g_crcT[t - 1][i] & 255];
}

// ================================================================ device state
struct GpuDev {
    int id = 0;
    char name[256] = {0};
    cudaStream_t st[2] = {0, 0};
    uint8_t *dIn[2] = {0, 0}, *dOut[2] = {0, 0};
    int32_t *dSz[2] = {0, 0};
    uint8_t *hIn[2] = {0, 0}, *hOut[2] = {0, 0};
    int32_t *hSz[2] = {0, 0};
};

static std::vector<GpuDev> g_dev;
static bool g_inited = false;
static int  g_cpuThreads = 1;
static std::vector<int64_t> g_workerChunks;    // size = nDev + 1
static std::vector<uint8_t> g_tmpOut;          // per-chunk output slots
static std::vector<int32_t> g_tmpSz;

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
    setErr(std::string("CUDA: ") + cudaGetErrorString(e_) + " at " #x); return false; } } while (0)

static bool devAlloc(GpuDev &d)
{
    CK(cudaSetDevice(d.id));
    size_t inBytes  = (size_t)GPU_SLOT_CHUNKS * MAX_CHUNK;
    size_t outBytes = (size_t)GPU_SLOT_CHUNKS * lz4Bound(MAX_CHUNK);
    for (int s = 0; s < 2; s++) {
        CK(cudaStreamCreateWithFlags(&d.st[s], cudaStreamNonBlocking));
        CK(cudaMalloc(&d.dIn[s], inBytes));
        CK(cudaMalloc(&d.dOut[s], outBytes));
        CK(cudaMalloc(&d.dSz[s], GPU_SLOT_CHUNKS * sizeof(int32_t)));
        CK(cudaMallocHost(&d.hIn[s], inBytes));
        CK(cudaMallocHost(&d.hOut[s], outBytes));
        CK(cudaMallocHost(&d.hSz[s], GPU_SLOT_CHUNKS * sizeof(int32_t)));
    }
    // warm-up launch so context creation is not counted in the first batch
    memset(d.hIn[0], 0, 4096);
    CK(cudaMemcpy(d.dIn[0], d.hIn[0], 4096, cudaMemcpyHostToDevice));
    lzKernel<<<1, WARPS_PER_BLK * 32>>>(d.dIn[0], 4096, 4096, 1, d.dOut[0], lz4Bound(4096), d.dSz[0]);
    CK(cudaGetLastError());
    CK(cudaDeviceSynchronize());
    return true;
}

static void devFree(GpuDev &d)
{
    cudaSetDevice(d.id);
    for (int s = 0; s < 2; s++) {
        if (d.st[s])  cudaStreamDestroy(d.st[s]);
        if (d.dIn[s]) cudaFree(d.dIn[s]);
        if (d.dOut[s]) cudaFree(d.dOut[s]);
        if (d.dSz[s]) cudaFree(d.dSz[s]);
        if (d.hIn[s]) cudaFreeHost(d.hIn[s]);
        if (d.hOut[s]) cudaFreeHost(d.hOut[s]);
        if (d.hSz[s]) cudaFreeHost(d.hSz[s]);
    }
}

// ================================================================ API: setup
extern "C" int gz_Init(void)
{
    std::call_once(g_crcOnce, crcInit);
    if (g_inited) return (int)g_dev.size();
    g_inited = true;
    unsigned hc = std::thread::hardware_concurrency();
    g_cpuThreads = hc ? (int)hc : 1;

    int n = 0;
    if (cudaGetDeviceCount(&n) != cudaSuccess) { n = 0; cudaGetLastError(); }
    for (int i = 0; i < n; i++) {
        GpuDev d;
        d.id = i;
        cudaDeviceProp pr;
        if (cudaGetDeviceProperties(&pr, i) == cudaSuccess)
            snprintf(d.name, sizeof d.name, "%.180s (sm_%d%d, %d SMs, %.1f GB)", pr.name, pr.major, pr.minor,
                     pr.multiProcessorCount, pr.totalGlobalMem / 1073741824.0);
        if (devAlloc(d)) g_dev.push_back(d);
        else devFree(d);
    }
    g_workerChunks.assign(g_dev.size() + 1, 0);
    return (int)g_dev.size();
}

extern "C" void gz_Shutdown(void)
{
    for (auto &d : g_dev) devFree(d);
    g_dev.clear();
    g_inited = false;
}

extern "C" int gz_DeviceCount(void) { return (int)g_dev.size(); }
extern "C" int gz_CpuThreads(void)  { return g_cpuThreads; }

static int copyOut(const std::string &s, char *buf, int cap)
{
    if (!buf || cap <= 0) return 0;
    int n = (int)s.size();
    if (n > cap - 1) n = cap - 1;
    memcpy(buf, s.data(), n);
    buf[n] = 0;
    return n;
}

extern "C" int gz_DeviceName(int idx, char *buf, int cap)
{
    if (idx < 0 || idx >= (int)g_dev.size()) return copyOut("", buf, cap);
    return copyOut(g_dev[idx].name, buf, cap);
}

extern "C" int gz_LastError(char *buf, int cap)
{
    std::lock_guard<std::mutex> lk(g_errLock);
    int n = copyOut(g_err, buf, cap);
    g_err.clear();
    return n;
}

extern "C" int64_t gz_ChunkCount(int64_t len, int chunkSize)
{
    if (chunkSize <= 0) return 0;
    return (len + chunkSize - 1) / chunkSize;
}

extern "C" int64_t gz_WorkerChunks(int idx)
{
    if (idx < 0 || idx >= (int)g_workerChunks.size()) return 0;
    return g_workerChunks[idx];
}

// ================================================================ API: compress
struct Job {
    const uint8_t *src;
    int64_t len;
    int cs, stride;
    int64_t nChunks, nGroups;
    std::atomic<int64_t> next{0};
    std::atomic<bool> failed{false};
};

// claim [g0, g1) groups; returns false when the queue is empty
static bool claim(Job &j, int want, int64_t &g0, int64_t &g1)
{
    g0 = j.next.fetch_add(want);
    if (g0 >= j.nGroups) return false;
    g1 = std::min<int64_t>(g0 + want, j.nGroups);
    return true;
}

static void cpuWorker(Job *j, int64_t *count)
{
    int64_t g0, g1, done = 0;
    while (!j->failed && claim(*j, 1, g0, g1)) {
        int64_t c0 = g0 * GROUP_CHUNKS, c1 = std::min<int64_t>(g1 * GROUP_CHUNKS, j->nChunks);
        for (int64_t c = c0; c < c1; c++) {
            int64_t off = c * j->cs;
            int n = (int)std::min<int64_t>(j->cs, j->len - off);
            g_tmpSz[c] = cpuCompressChunk(j->src + off, n, &g_tmpOut[(size_t)c * j->stride]);
            done++;
        }
    }
    *count = done;
}

static void gpuWorker(Job *j, GpuDev *d, int64_t *count)
{
    int64_t done = 0;
    int64_t pendC0[2] = {-1, -1}, pendCnt[2] = {0, 0};
    if (cudaSetDevice(d->id) != cudaSuccess) { setErr("cudaSetDevice failed"); j->failed = true; *count = 0; return; }

    auto harvest = [&](int s) -> bool {
        if (pendC0[s] < 0) return true;
        cudaError_t e = cudaStreamSynchronize(d->st[s]);
        if (e != cudaSuccess) { setErr(std::string("CUDA: ") + cudaGetErrorString(e)); return false; }
        for (int64_t i = 0; i < pendCnt[s]; i++) {
            int64_t c = pendC0[s] + i;
            int32_t sz = d->hSz[s][i];
            if (sz <= 0 || sz > j->stride) sz = 0;      // bad result -> chunk gets stored raw
            g_tmpSz[c] = sz;
            if (sz) memcpy(&g_tmpOut[(size_t)c * j->stride], d->hOut[s] + (size_t)i * j->stride, sz);
        }
        done += pendCnt[s];
        pendC0[s] = -1;
        return true;
    };

    int s = 0;
    int64_t g0, g1;
    while (!j->failed && claim(*j, GPU_GROUPS, g0, g1)) {
        if (!harvest(s)) { j->failed = true; break; }
        int64_t c0 = g0 * GROUP_CHUNKS;
        int64_t c1 = std::min<int64_t>(g1 * GROUP_CHUNKS, j->nChunks);
        int cnt = (int)(c1 - c0);
        int64_t off = c0 * j->cs;
        int bytes = (int)std::min<int64_t>((int64_t)cnt * j->cs, j->len - off);

        memcpy(d->hIn[s], j->src + off, bytes);
        cudaMemcpyAsync(d->dIn[s], d->hIn[s], bytes, cudaMemcpyHostToDevice, d->st[s]);
        int blocks = (cnt + WARPS_PER_BLK - 1) / WARPS_PER_BLK;
        lzKernel<<<blocks, WARPS_PER_BLK * 32, 0, d->st[s]>>>(d->dIn[s], bytes, j->cs, cnt,
                                                               d->dOut[s], j->stride, d->dSz[s]);
        cudaMemcpyAsync(d->hSz[s], d->dSz[s], cnt * sizeof(int32_t), cudaMemcpyDeviceToHost, d->st[s]);
        cudaMemcpyAsync(d->hOut[s], d->dOut[s], (size_t)cnt * j->stride, cudaMemcpyDeviceToHost, d->st[s]);
        cudaError_t e = cudaGetLastError();
        if (e != cudaSuccess) { setErr(std::string("CUDA launch: ") + cudaGetErrorString(e)); j->failed = true; break; }
        pendC0[s] = c0;
        pendCnt[s] = cnt;
        s ^= 1;
    }
    if (!harvest(0) || !harvest(1)) j->failed = true;
    *count = done;
}

extern "C" int64_t gz_CompressBatch(intptr_t srcP, int64_t srcLen, int chunkSize,
                                    intptr_t dstP, intptr_t sizesP, int mode)
{
    const void *src = (const void *)srcP;
    void *dst = (void *)dstP;
    int32_t *sizes = (int32_t *)sizesP;
    if (!g_inited) gz_Init();
    if (!src || !dst || !sizes || srcLen < 0) { setErr("bad arguments"); return -1; }
    if (chunkSize < 64 || chunkSize > MAX_CHUNK) { setErr("chunkSize must be 64..65536"); return -1; }
    if (srcLen == 0) return 0;

    Job j;
    j.src = (const uint8_t *)src;
    j.len = srcLen;
    j.cs = chunkSize;
    j.stride = lz4Bound(chunkSize);
    j.nChunks = gz_ChunkCount(srcLen, chunkSize);
    j.nGroups = (j.nChunks + GROUP_CHUNKS - 1) / GROUP_CHUNKS;

    size_t need = (size_t)j.nChunks * j.stride;
    if (g_tmpOut.size() < need) g_tmpOut.resize(need);
    if (g_tmpSz.size() < (size_t)j.nChunks) g_tmpSz.resize(j.nChunks);

    int nDev = (int)g_dev.size();
    std::vector<int> gpus;
    int cpuN = 0;
    if (mode == -1 || nDev == 0) {
        cpuN = g_cpuThreads;
    } else if (mode == -2) {
        for (int i = 0; i < nDev; i++) gpus.push_back(i);
        cpuN = std::max(1, g_cpuThreads - nDev);   // leave one core per GPU feeder
    } else if (mode == 0) {
        for (int i = 0; i < nDev; i++) gpus.push_back(i);
    } else if (mode >= 1 && mode <= nDev) {
        gpus.push_back(mode - 1);
    } else {
        setErr("bad mode");
        return -1;
    }

    std::vector<int64_t> cnt(nDev + 1 + cpuN, 0);
    std::vector<std::thread> th;
    for (size_t k = 0; k < gpus.size(); k++)
        th.emplace_back(gpuWorker, &j, &g_dev[gpus[k]], &cnt[gpus[k]]);
    for (int k = 0; k < cpuN; k++)
        th.emplace_back(cpuWorker, &j, &cnt[nDev + 1 + k]);
    for (auto &t : th) t.join();
    if (j.failed) return -1;

    g_workerChunks.assign(nDev + 1, 0);
    for (int i = 0; i < nDev; i++) g_workerChunks[i] = cnt[i];
    for (int k = 0; k < cpuN; k++) g_workerChunks[nDev] += cnt[nDev + 1 + k];

    // pack in chunk order; anything that did not shrink is stored raw
    uint8_t *o = (uint8_t *)dst;
    int64_t total = 0;
    for (int64_t c = 0; c < j.nChunks; c++) {
        int64_t off = c * chunkSize;
        int n = (int)std::min<int64_t>(chunkSize, srcLen - off);
        int32_t sz = g_tmpSz[c];
        if (sz <= 0 || sz >= n) {
            memcpy(o + total, j.src + off, n);
            sizes[c] = -n;
            total += n;
        } else {
            memcpy(o + total, &g_tmpOut[(size_t)c * j.stride], sz);
            sizes[c] = sz;
            total += sz;
        }
    }
    return total;
}

// ================================================================ API: decompress
extern "C" int gz_DecompressBatch(intptr_t srcP, int64_t srcLen, intptr_t sizesP,
                                  int nChunks, int chunkSize, int64_t rawLen, intptr_t dstP)
{
    const void *src = (const void *)srcP;
    const int32_t *sizes = (const int32_t *)sizesP;
    void *dst = (void *)dstP;
    if (!g_inited) gz_Init();
    if (nChunks <= 0) return 0;
    if (gz_ChunkCount(rawLen, chunkSize) != nChunks) { setErr("rawLen / chunk count mismatch"); return -1; }
    std::vector<int64_t> soff(nChunks);
    int64_t acc = 0;
    for (int c = 0; c < nChunks; c++) {
        soff[c] = acc;
        acc += sizes[c] < 0 ? -(int64_t)sizes[c] : sizes[c];
    }
    if (acc > srcLen) { setErr("chunk table larger than data"); return -1; }

    std::atomic<int> next{0}, bad{0};
    auto work = [&]() {
        for (;;) {
            int c = next.fetch_add(1);
            if (c >= nChunks || bad) return;
            int64_t roff = (int64_t)c * chunkSize;
            int n = (int)std::min<int64_t>(chunkSize, rawLen - roff);
            const uint8_t *s = (const uint8_t *)src + soff[c];
            uint8_t *d = (uint8_t *)dst + roff;
            int sz = sizes[c];
            if (sz < 0) {
                if (-sz != n) { int z = 0; bad.compare_exchange_strong(z, c + 1); return; }
                memcpy(d, s, n);
            } else if (lz4Decode(s, sz, d, n) != n) {
                int z = 0; bad.compare_exchange_strong(z, c + 1); return;
            }
        }
    };
    int nt = std::min(g_cpuThreads, nChunks);
    std::vector<std::thread> th;
    for (int k = 0; k < nt; k++) th.emplace_back(work);
    for (auto &t : th) t.join();
    if (bad) { setErr("corrupt chunk " + std::to_string(bad - 1)); return -bad; }
    return 0;
}

// ================================================================ API: helpers
extern "C" uint32_t gz_Crc32(intptr_t pP, int64_t len, uint32_t crc)
{
    const void *p = (const void *)pP;
    std::call_once(g_crcOnce, crcInit);
    const uint8_t *b = (const uint8_t *)p;
    crc = ~crc;
    while (len >= 8) {
        uint32_t a = crc ^ rd32(b);
        uint32_t c = rd32(b + 4);
        crc = g_crcT[7][a & 255] ^ g_crcT[6][(a >> 8) & 255] ^ g_crcT[5][(a >> 16) & 255] ^ g_crcT[4][a >> 24] ^
              g_crcT[3][c & 255] ^ g_crcT[2][(c >> 8) & 255] ^ g_crcT[1][(c >> 16) & 255] ^ g_crcT[0][c >> 24];
        b += 8; len -= 8;
    }
    while (len-- > 0) crc = g_crcT[0][(crc ^ *b++) & 255] ^ (crc >> 8);
    return ~crc;
}

struct ScanEnt { std::string path; int64_t size; int type; };
static std::vector<ScanEnt> g_scan;
static size_t g_scanRootLen = 0;

static int scanCb(const char *fpath, const struct stat *sb, int tflag, struct FTW *ftwbuf)
{
    if (ftwbuf->level == 0) return 0;                 // the root itself
    const char *rel = fpath + g_scanRootLen;
    while (*rel == '/') rel++;
    if (tflag == FTW_F && S_ISREG(sb->st_mode)) g_scan.push_back({rel, (int64_t)sb->st_size, 0});
    else if (tflag == FTW_D) g_scan.push_back({rel, 0, 1});
    return 0;                                          // symlinks, sockets, etc. are skipped
}

extern "C" int gz_ScanFolder(const char *root)
{
    g_scan.clear();
    if (!root) return -1;
    std::string r(root);
    while (r.size() > 1 && r.back() == '/') r.pop_back();
    g_scanRootLen = r.size();
    if (nftw(r.c_str(), scanCb, 32, FTW_PHYS) != 0) { setErr("cannot read folder " + r); return -1; }
    // directories first is not needed; sort by path so the order is stable and
    // files from the same folder sit next to each other in the solid stream
    std::sort(g_scan.begin(), g_scan.end(), [](const ScanEnt &a, const ScanEnt &b) { return a.path < b.path; });
    return (int)g_scan.size();
}

extern "C" int gz_ScanPath(int idx, char *buf, int cap)
{
    if (idx < 0 || idx >= (int)g_scan.size()) return copyOut("", buf, cap);
    return copyOut(g_scan[idx].path, buf, cap);
}
extern "C" int64_t gz_ScanSize(int idx) { return (idx < 0 || idx >= (int)g_scan.size()) ? 0 : g_scan[idx].size; }
extern "C" int gz_ScanType(int idx) { return (idx < 0 || idx >= (int)g_scan.size()) ? 0 : g_scan[idx].type; }

extern "C" int gz_MkdirP(const char *path)
{
    if (!path || !*path) return -1;
    std::string p(path);
    for (size_t i = 1; i <= p.size(); i++) {
        if (i == p.size() || p[i] == '/') {
            std::string part = p.substr(0, i);
            if (mkdir(part.c_str(), 0755) != 0 && errno != EEXIST) return -1;
        }
    }
    struct stat st;
    return (stat(path, &st) == 0 && S_ISDIR(st.st_mode)) ? 0 : -1;
}

// ================================================================ API: file I/O
// Plain POSIX I/O so the QB64 side gets the real error text (disk full, read-only,
// file too large...) instead of a generic runtime error, and so data moves straight
// between disk and the _MEM buffers with no string copies.
#include <fcntl.h>
#include <unistd.h>
#include <sys/statvfs.h>

extern "C" int gz_FCreate(const char *path)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    return fd >= 0 ? fd : -errno;
}

extern "C" int gz_FOpenR(const char *path)
{
    int fd = open(path, O_RDONLY);
    return fd >= 0 ? fd : -errno;
}

extern "C" int gz_FWrite(int fd, intptr_t p, int64_t len)
{
    const uint8_t *b = (const uint8_t *)p;
    while (len > 0) {
        ssize_t w = write(fd, b, len > (1 << 30) ? (1 << 30) : (size_t)len);
        if (w < 0) { if (errno == EINTR) continue; return errno; }
        if (w == 0) return ENOSPC;
        b += w; len -= w;
    }
    return 0;
}

extern "C" int gz_FWriteAt(int fd, intptr_t p, int64_t len, int64_t offset)
{
    const uint8_t *b = (const uint8_t *)p;
    while (len > 0) {
        ssize_t w = pwrite(fd, b, len > (1 << 30) ? (1 << 30) : (size_t)len, offset);
        if (w < 0) { if (errno == EINTR) continue; return errno; }
        if (w == 0) return ENOSPC;
        b += w; len -= w; offset += w;
    }
    return 0;
}

// returns bytes read (0 = end of file) or -errno
extern "C" int64_t gz_FRead(int fd, intptr_t p, int64_t len)
{
    uint8_t *b = (uint8_t *)p;
    int64_t got = 0;
    while (got < len) {
        ssize_t r = read(fd, b + got, (len - got) > (1 << 30) ? (1 << 30) : (size_t)(len - got));
        if (r < 0) { if (errno == EINTR) continue; return -errno; }
        if (r == 0) break;
        got += r;
    }
    return got;
}

extern "C" int gz_FClose(int fd)
{
    if (fd < 0) return 0;
    return close(fd) == 0 ? 0 : errno;
}

// flush to the drive; reports late write errors (used once, on the finished archive)
extern "C" int gz_FSync(int fd)
{
    return (fsync(fd) == 0 || errno == EINVAL) ? 0 : errno;
}

extern "C" int gz_FDelete(const char *path) { return unlink(path) == 0 ? 0 : errno; }

extern "C" int gz_ErrText(int code, char *buf, int cap)
{
    if (code < 0) code = -code;
    return copyOut(strerror(code), buf, cap);
}

// free bytes for this user on the drive holding 'path' (a folder), or -1
extern "C" int64_t gz_FreeSpace(const char *path)
{
    struct statvfs s;
    if (statvfs(path, &s) != 0) return -1;
    return (int64_t)s.f_bavail * (int64_t)s.f_frsize;
}

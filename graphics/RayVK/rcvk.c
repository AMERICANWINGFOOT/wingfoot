/* rcvk.c -- RayVK: Vulkan compute ray caster library for QB64-PE (librcvk.so)
 *
 * Vulkan counterpart of librcgpu.so: same idea, but it runs on any Vulkan GPU,
 * including the Intel Arc B580 (and the GTX 745s, and even the CPU's llvmpipe).
 *
 * Frame path: compute shader -> device-local frame buffer -> copy to a
 * host-cached readback buffer -> memcpy into QB64's screen image (_MEMIMAGE).
 *
 * Build:  ./build.sh      (gcc -O2 -shared -fPIC rcvk.c -o librcvk.so -l:libvulkan.so.1)
 * Needs headers from libvulkan-dev to build; only libvulkan1 to run.
 */
#include <vulkan/vulkan.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>

#include "rcvk_spv.h"

#define TEXSZ    64
#define TEXPIX   (TEXSZ * TEXSZ)
#define MAXTEX   64
#define MAXSPR   1024
#define MAXDEV   16

typedef struct {
    float pos[2], dir[2], plane[2];
    int32_t w, h, mw, mh;
    float fogDist;
    uint32_t fogColor;
    int32_t shadeSides, nSpr, nTex;
} PushC;   /* must match the shader's push_constant block: 60 bytes */

typedef struct {
    VkBuffer buf;
    VkDeviceMemory mem;
    VkDeviceSize size;
    void *map;          /* non-NULL when host-visible and mapped */
    int coherent;
} Buf;

static struct {
    VkInstance inst;
    VkPhysicalDevice phys[MAXDEV];
    uint32_t nphys;
    int devIndex;
    VkPhysicalDevice pd;
    VkDevice dev;
    VkQueue q;
    uint32_t qfam;
    VkCommandPool cpool;
    VkCommandBuffer cb;
    VkFence fence;
    VkQueryPool qpool;
    float tsPeriod;
    int tsValid;

    VkShaderModule sm;
    VkDescriptorSetLayout dsl;
    VkPipelineLayout pl;
    VkPipeline pipe;
    VkDescriptorPool dpool;
    VkDescriptorSet ds;

    Buf out, readback, mapb, texb, sprb, staging;

    int w, h, mw, mh;
    uint32_t *cells;                 /* CPU copy of the packed map */
    uint32_t *tex;                   /* CPU copy of all textures */
    int nTex;
    int mapDirty, texDirty;
    int texLo, texHi;                /* range of texture ids changed since the last frame */
    VkDeviceSize stageTexOff;        /* textures go here in the staging buffer, the map at 0 */
    int nSpr;

    float camX, camY, camAng;
    float fogDist;
    uint32_t fogColor;
    int shadeSides;

    float gpuMs, hostMs;
    float copyMs, waitMs, memcpyMs;
    int mode;               /* readback method, see rv_set_mode */
    char modeDesc[80];
    int ready;
} S;

static char g_err[512] = "no error";

static void seterr(const char *msg, VkResult r) {
    if (r != VK_SUCCESS) snprintf(g_err, sizeof g_err, "%s (VkResult %d)", msg, (int)r);
    else snprintf(g_err, sizeof g_err, "%s", msg);
}

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000.0 + t.tv_nsec / 1e6;
}

/* ---------------- instance / device enumeration ---------------- */

static int ensure_instance(void) {
    if (S.inst) return 1;
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO };
    app.pApplicationName = "RayVK";
    app.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    ici.pApplicationInfo = &app;
    VkResult r = vkCreateInstance(&ici, NULL, &S.inst);
    if (r != VK_SUCCESS) { S.inst = NULL; seterr("vkCreateInstance failed - is a Vulkan driver installed?", r); return 0; }
    S.nphys = MAXDEV;
    r = vkEnumeratePhysicalDevices(S.inst, &S.nphys, S.phys);
    if (r != VK_SUCCESS && r != VK_INCOMPLETE) { seterr("vkEnumeratePhysicalDevices failed", r); return 0; }
    if (S.nphys == 0) { seterr("no Vulkan devices found", VK_SUCCESS); return 0; }
    return 1;
}

int rv_device_count(void) {
    if (!ensure_instance()) return 0;
    return (int)S.nphys;
}

/* name of device i (0-based), or of the active device when i < 0 */
void rv_device_name(int i, char *buf, int len) {
    if (!buf || len <= 0) return;
    buf[0] = 0;
    if (!ensure_instance()) return;
    VkPhysicalDevice p = (i < 0) ? S.pd : ((uint32_t)i < S.nphys ? S.phys[i] : NULL);
    if (!p) return;
    VkPhysicalDeviceProperties pr;
    vkGetPhysicalDeviceProperties(p, &pr);
    snprintf(buf, (size_t)len, "%s", pr.deviceName);
    /* QB64 fixed strings are space padded, not 0 terminated: pad the rest */
    size_t n = strlen(buf);
    for (int k = (int)n; k < len; k++) buf[k] = ' ';
}

int rv_current_device(void) { return S.ready ? S.devIndex : -1; }

/* auto pick: Intel discrete > any discrete > integrated > anything */
static int pick_device(void) {
    int best = -1, bestScore = -1;
    for (uint32_t i = 0; i < S.nphys; i++) {
        VkPhysicalDeviceProperties pr;
        vkGetPhysicalDeviceProperties(S.phys[i], &pr);
        int sc = 1;
        if (pr.deviceType == VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU) sc = 10;
        if (pr.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) sc = 20;
        if (pr.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU && pr.vendorID == 0x8086) sc = 30;
        if (sc > bestScore) { bestScore = sc; best = (int)i; }
    }
    return best;
}

/* ---------------- buffers ---------------- */

static int find_mem2(uint32_t bits, VkMemoryPropertyFlags want, VkMemoryPropertyFlags avoid, VkMemoryPropertyFlags *got) {
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(S.pd, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want &&
            (mp.memoryTypes[i].propertyFlags & avoid) == 0) {
            if (got) *got = mp.memoryTypes[i].propertyFlags;
            return (int)i;
        }
    return -1;
}

static int find_mem(uint32_t bits, VkMemoryPropertyFlags want, VkMemoryPropertyFlags *got) {
    return find_mem2(bits, want, 0, got);
}

/* buffer memory kinds */
#define MEM_DEVICE       0   /* VRAM, not mappable */
#define MEM_HOST_CACHED  1   /* system RAM, CPU cached (falls back to coherent) */
#define MEM_HOST_UNCACHED 2  /* system RAM, coherent, not CPU cached */
#define MEM_DEVICE_HOST  3   /* VRAM the CPU can map (resizable BAR window) */

static int make_buf(Buf *b, VkDeviceSize size, VkBufferUsageFlags usage, int kind) {
    memset(b, 0, sizeof *b);
    b->size = size;
    VkBufferCreateInfo bi = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    bi.size = size;
    bi.usage = usage;
    bi.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    VkResult r = vkCreateBuffer(S.dev, &bi, NULL, &b->buf);
    if (r != VK_SUCCESS) { seterr("vkCreateBuffer failed", r); return 0; }
    VkMemoryRequirements mr;
    vkGetBufferMemoryRequirements(S.dev, b->buf, &mr);
    VkMemoryPropertyFlags got = 0;
    int mt;
    if (kind == MEM_HOST_CACHED) {
        mt = find_mem2(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_CACHED_BIT,
                       VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, &got);
        if (mt < 0) mt = find_mem(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_CACHED_BIT, &got);
        if (mt < 0) mt = find_mem(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &got);
    } else if (kind == MEM_HOST_UNCACHED) {
        mt = find_mem2(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                       VK_MEMORY_PROPERTY_HOST_CACHED_BIT | VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, &got);
        if (mt < 0) mt = find_mem(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, &got);
    } else if (kind == MEM_DEVICE_HOST) {
        mt = find_mem(mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT | VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, &got);
    } else {
        mt = find_mem(mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, &got);
        if (mt < 0) mt = find_mem(mr.memoryTypeBits, 0, &got);
    }
    if (mt < 0) { seterr("no suitable memory type", VK_SUCCESS); return 0; }
    VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    ai.allocationSize = mr.size;
    ai.memoryTypeIndex = (uint32_t)mt;
    r = vkAllocateMemory(S.dev, &ai, NULL, &b->mem);
    if (r != VK_SUCCESS) { seterr("vkAllocateMemory failed", r); return 0; }
    vkBindBufferMemory(S.dev, b->buf, b->mem, 0);
    if (kind != MEM_DEVICE) {
        r = vkMapMemory(S.dev, b->mem, 0, VK_WHOLE_SIZE, 0, &b->map);
        if (r != VK_SUCCESS) { seterr("vkMapMemory failed", r); return 0; }
        b->coherent = (got & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0;
    }
    return 1;
}

static void free_buf(Buf *b) {
    if (!S.dev) return;
    if (b->map) vkUnmapMemory(S.dev, b->mem);
    if (b->buf) vkDestroyBuffer(S.dev, b->buf, NULL);
    if (b->mem) vkFreeMemory(S.dev, b->mem, NULL);
    memset(b, 0, sizeof *b);
}

static void flush_buf(Buf *b) {
    if (b->coherent || !b->map) return;
    VkMappedMemoryRange mr = { VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE };
    mr.memory = b->mem; mr.size = VK_WHOLE_SIZE;
    vkFlushMappedMemoryRanges(S.dev, 1, &mr);
}

static void invalidate_buf(Buf *b) {
    if (b->coherent || !b->map) return;
    VkMappedMemoryRange mr = { VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE };
    mr.memory = b->mem; mr.size = VK_WHOLE_SIZE;
    vkInvalidateMappedMemoryRanges(S.dev, 1, &mr);
}

static int submit_wait(void) {
    VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
    si.commandBufferCount = 1;
    si.pCommandBuffers = &S.cb;
    vkResetFences(S.dev, 1, &S.fence);
    VkResult r = vkQueueSubmit(S.q, 1, &si, S.fence);
    if (r != VK_SUCCESS) { seterr("vkQueueSubmit failed", r); return 0; }
    r = vkWaitForFences(S.dev, 1, &S.fence, VK_TRUE, 5000000000ull);
    if (r != VK_SUCCESS) { seterr("GPU did not finish (timeout or device lost)", r); return 0; }
    return 1;
}

static void begin_cb(void) {
    vkResetCommandBuffer(S.cb, 0);
    VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(S.cb, &bi);
}

/* Record pending map/texture uploads into the frame's command buffer (call right
 * after begin_cb). The barrier after the copies makes the new data visible to the
 * compute shader. Without it, Intel GPUs could read the buffer before the copy was
 * visible and draw black walls/floors; NVIDIA's driver happened to hide that. */
static void record_uploads(void) {
    int haveMap = S.mapDirty;
    int haveTex = S.texDirty && S.texHi >= S.texLo;
    if (!haveMap && !haveTex) { S.texDirty = 0; return; }

    /* last frame's shader reads finish before we overwrite those buffers */
    vkCmdPipelineBarrier(S.cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         0, 0, NULL, 0, NULL, 0, NULL);
    if (haveMap) {
        memcpy(S.staging.map, S.cells, (size_t)S.mapb.size);
        VkBufferCopy c = { 0, 0, S.mapb.size };
        vkCmdCopyBuffer(S.cb, S.staging.buf, S.mapb.buf, 1, &c);
    }
    if (haveTex) {
        /* only the textures that changed, e.g. 16 KB for one sliding door */
        VkDeviceSize off = (VkDeviceSize)(S.texLo - 1) * TEXPIX * 4;
        VkDeviceSize len = (VkDeviceSize)(S.texHi - S.texLo + 1) * TEXPIX * 4;
        memcpy((uint8_t *)S.staging.map + S.stageTexOff + off, (const uint8_t *)S.tex + off, (size_t)len);
        VkBufferCopy c = { S.stageTexOff + off, off, len };
        vkCmdCopyBuffer(S.cb, S.staging.buf, S.texb.buf, 1, &c);
    }
    flush_buf(&S.staging);

    VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER };
    mb.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    mb.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    vkCmdPipelineBarrier(S.cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                         0, 1, &mb, 0, NULL, 0, NULL);

    S.mapDirty = 0;
    S.texDirty = 0; S.texLo = MAXTEX + 1; S.texHi = 0;
}

/* ---------------- frame buffers / readback modes ----------------
 * 0: shader -> VRAM, GPU copies to cached system RAM, CPU reads it   (default)
 * 1: shader -> VRAM, GPU copies to uncached system RAM, CPU reads it
 * 2: shader writes straight into cached system RAM (no copy)
 * 3: shader -> VRAM the CPU maps directly (needs resizable BAR to be fast) */
static int make_frame_bufs(void) {
    VkDeviceSize bytes = (VkDeviceSize)S.w * S.h * 4;
    const VkBufferUsageFlags SB = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    int ok = 0;
    free_buf(&S.out);
    free_buf(&S.readback);
    switch (S.mode) {
    case 0:
        ok = make_buf(&S.out, bytes, SB | VK_BUFFER_USAGE_TRANSFER_SRC_BIT, MEM_DEVICE) &&
             make_buf(&S.readback, bytes, VK_BUFFER_USAGE_TRANSFER_DST_BIT, MEM_HOST_CACHED);
        snprintf(S.modeDesc, sizeof S.modeDesc, "0: VRAM, GPU copy to cached RAM");
        break;
    case 1:
        ok = make_buf(&S.out, bytes, SB | VK_BUFFER_USAGE_TRANSFER_SRC_BIT, MEM_DEVICE) &&
             make_buf(&S.readback, bytes, VK_BUFFER_USAGE_TRANSFER_DST_BIT, MEM_HOST_UNCACHED);
        snprintf(S.modeDesc, sizeof S.modeDesc, "1: VRAM, GPU copy to uncached RAM");
        break;
    case 2:
        ok = make_buf(&S.out, bytes, SB, MEM_HOST_CACHED);
        snprintf(S.modeDesc, sizeof S.modeDesc, "2: shader writes to system RAM");
        break;
    case 3:
        ok = make_buf(&S.out, bytes, SB, MEM_DEVICE_HOST);
        snprintf(S.modeDesc, sizeof S.modeDesc, "3: CPU reads VRAM directly (BAR)");
        break;
    }
    if (!ok) return 0;
    VkDescriptorBufferInfo bi = { S.out.buf, 0, VK_WHOLE_SIZE };
    VkWriteDescriptorSet w;
    memset(&w, 0, sizeof w);
    w.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    w.dstSet = S.ds; w.dstBinding = 0; w.descriptorCount = 1;
    w.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER; w.pBufferInfo = &bi;
    vkUpdateDescriptorSets(S.dev, 1, &w, 0, NULL);
    return 1;
}

/* switch readback method 0..3; returns 1 if the mode works on this device */
int rv_set_mode(int mode) {
    if (!S.ready || mode < 0 || mode > 3) return 0;
    vkDeviceWaitIdle(S.dev);
    S.mode = mode;
    if (make_frame_bufs()) return 1;
    S.mode = 0;
    make_frame_bufs();
    return 0;
}

int rv_mode(void) { return S.mode; }

void rv_mode_name(char *buf, int len) {
    if (!buf || len <= 0) return;
    int n = (int)strlen(S.modeDesc);
    for (int i = 0; i < len; i++) buf[i] = (i < n) ? S.modeDesc[i] : ' ';
}

/* size in MB of the largest VRAM heap the CPU can map: about 256 = no resizable BAR,
 * about the full VRAM size = resizable BAR is on. 0 = none. */
int rv_rebar_mb(void) {
    if (!S.ready) return 0;
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(S.pd, &mp);
    VkDeviceSize best = 0;
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++) {
        VkMemoryPropertyFlags f = mp.memoryTypes[i].propertyFlags;
        if ((f & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) && (f & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) {
            VkDeviceSize hs = mp.memoryHeaps[mp.memoryTypes[i].heapIndex].size;
            if (hs > best) best = hs;
        }
    }
    return (int)(best / (1024 * 1024));
}

/* ---------------- lifetime ---------------- */

void rv_shutdown(void) {
    if (S.dev) {
        vkDeviceWaitIdle(S.dev);
        free_buf(&S.out); free_buf(&S.readback); free_buf(&S.mapb);
        free_buf(&S.texb); free_buf(&S.sprb); free_buf(&S.staging);
        if (S.pipe) vkDestroyPipeline(S.dev, S.pipe, NULL);
        if (S.pl) vkDestroyPipelineLayout(S.dev, S.pl, NULL);
        if (S.dpool) vkDestroyDescriptorPool(S.dev, S.dpool, NULL);
        if (S.dsl) vkDestroyDescriptorSetLayout(S.dev, S.dsl, NULL);
        if (S.sm) vkDestroyShaderModule(S.dev, S.sm, NULL);
        if (S.qpool) vkDestroyQueryPool(S.dev, S.qpool, NULL);
        if (S.fence) vkDestroyFence(S.dev, S.fence, NULL);
        if (S.cpool) vkDestroyCommandPool(S.dev, S.cpool, NULL);
        vkDestroyDevice(S.dev, NULL);
    }
    if (S.inst) vkDestroyInstance(S.inst, NULL);
    free(S.cells);
    free(S.tex);
    memset(&S, 0, sizeof S);
}

/* dev: device index from rv_device_name list, or -1 for automatic.
 * Returns 1 on success, 0 on failure (see rv_last_error). */
int rv_init(int dev, int w, int h, int mw, int mh) {
    VkResult r;
    rv_shutdown();
    if (w < 16 || h < 16 || mw < 1 || mh < 1) { seterr("bad size arguments", VK_SUCCESS); return 0; }
    if (!ensure_instance()) return 0;

    if (dev < 0 || (uint32_t)dev >= S.nphys) dev = pick_device();
    S.devIndex = dev;
    S.pd = S.phys[dev];

    /* compute-capable queue */
    uint32_t nq = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(S.pd, &nq, NULL);
    VkQueueFamilyProperties qf[32];
    if (nq > 32) nq = 32;
    vkGetPhysicalDeviceQueueFamilyProperties(S.pd, &nq, qf);
    int fam = -1;
    for (uint32_t i = 0; i < nq; i++)
        if (qf[i].queueFlags & VK_QUEUE_COMPUTE_BIT) { fam = (int)i; break; }
    if (fam < 0) { seterr("device has no compute queue", VK_SUCCESS); rv_shutdown(); return 0; }
    S.qfam = (uint32_t)fam;
    S.tsValid = qf[fam].timestampValidBits != 0;

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
    qci.queueFamilyIndex = S.qfam; qci.queueCount = 1; qci.pQueuePriorities = &prio;
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
    dci.queueCreateInfoCount = 1; dci.pQueueCreateInfos = &qci;
    r = vkCreateDevice(S.pd, &dci, NULL, &S.dev);
    if (r != VK_SUCCESS) { S.dev = NULL; seterr("vkCreateDevice failed", r); rv_shutdown(); return 0; }
    vkGetDeviceQueue(S.dev, S.qfam, 0, &S.q);

    VkPhysicalDeviceProperties pr;
    vkGetPhysicalDeviceProperties(S.pd, &pr);
    S.tsPeriod = pr.limits.timestampPeriod;

    VkCommandPoolCreateInfo cpi = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
    cpi.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    cpi.queueFamilyIndex = S.qfam;
    vkCreateCommandPool(S.dev, &cpi, NULL, &S.cpool);
    VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    cai.commandPool = S.cpool; cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; cai.commandBufferCount = 1;
    vkAllocateCommandBuffers(S.dev, &cai, &S.cb);
    VkFenceCreateInfo fci = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    vkCreateFence(S.dev, &fci, NULL, &S.fence);
    if (S.tsValid) {
        VkQueryPoolCreateInfo qpi = { VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO };
        qpi.queryType = VK_QUERY_TYPE_TIMESTAMP; qpi.queryCount = 3;
        if (vkCreateQueryPool(S.dev, &qpi, NULL, &S.qpool) != VK_SUCCESS) { S.qpool = NULL; S.tsValid = 0; }
    }

    /* buffers */
    S.w = w; S.h = h; S.mw = mw; S.mh = mh;
    VkDeviceSize frameBytes = (VkDeviceSize)w * h * 4;
    VkDeviceSize mapBytes = (VkDeviceSize)mw * mh * 4;
    VkDeviceSize texBytes = (VkDeviceSize)MAXTEX * TEXPIX * 4;
    /* map and textures side by side, so both can upload in the same frame */
    S.stageTexOff = (mapBytes + 255) & ~(VkDeviceSize)255;
    VkDeviceSize stageBytes = S.stageTexOff + texBytes;
    const VkBufferUsageFlags SB = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    (void)frameBytes;
    if (!make_buf(&S.mapb, mapBytes, SB | VK_BUFFER_USAGE_TRANSFER_DST_BIT, 0) ||
        !make_buf(&S.texb, texBytes, SB | VK_BUFFER_USAGE_TRANSFER_DST_BIT, 0) ||
        !make_buf(&S.sprb, (VkDeviceSize)MAXSPR * 16, SB, 1) ||
        !make_buf(&S.staging, stageBytes, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, 1)) {
        rv_shutdown(); return 0;
    }

    S.cells = (uint32_t *)calloc((size_t)mw * mh, 4);
    S.tex = (uint32_t *)calloc((size_t)MAXTEX * TEXPIX, 4);
    if (!S.cells || !S.tex) { seterr("out of memory", VK_SUCCESS); rv_shutdown(); return 0; }
    S.mapDirty = S.texDirty = 1;
    S.texLo = 1; S.texHi = MAXTEX;   /* first frame uploads every slot (zeros if unset) */

    /* pipeline */
    VkShaderModuleCreateInfo smi = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
    smi.codeSize = rcvk_spv_size; smi.pCode = rcvk_spv;
    r = vkCreateShaderModule(S.dev, &smi, NULL, &S.sm);
    if (r != VK_SUCCESS) { seterr("vkCreateShaderModule failed", r); rv_shutdown(); return 0; }

    VkDescriptorSetLayoutBinding b[4];
    memset(b, 0, sizeof b);
    for (int i = 0; i < 4; i++) {
        b[i].binding = (uint32_t)i;
        b[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        b[i].descriptorCount = 1;
        b[i].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    }
    VkDescriptorSetLayoutCreateInfo dli = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO };
    dli.bindingCount = 4; dli.pBindings = b;
    vkCreateDescriptorSetLayout(S.dev, &dli, NULL, &S.dsl);

    VkPushConstantRange pcr = { VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(PushC) };
    VkPipelineLayoutCreateInfo pli = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    pli.setLayoutCount = 1; pli.pSetLayouts = &S.dsl;
    pli.pushConstantRangeCount = 1; pli.pPushConstantRanges = &pcr;
    vkCreatePipelineLayout(S.dev, &pli, NULL, &S.pl);

    VkComputePipelineCreateInfo cpci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO };
    cpci.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    cpci.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    cpci.stage.module = S.sm;
    cpci.stage.pName = "main";
    cpci.layout = S.pl;
    r = vkCreateComputePipelines(S.dev, VK_NULL_HANDLE, 1, &cpci, NULL, &S.pipe);
    if (r != VK_SUCCESS) { seterr("vkCreateComputePipelines failed", r); rv_shutdown(); return 0; }

    VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 4 };
    VkDescriptorPoolCreateInfo dpi = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO };
    dpi.maxSets = 1; dpi.poolSizeCount = 1; dpi.pPoolSizes = &ps;
    vkCreateDescriptorPool(S.dev, &dpi, NULL, &S.dpool);
    VkDescriptorSetAllocateInfo dai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO };
    dai.descriptorPool = S.dpool; dai.descriptorSetCount = 1; dai.pSetLayouts = &S.dsl;
    vkAllocateDescriptorSets(S.dev, &dai, &S.ds);

    VkDescriptorBufferInfo dbi[4] = {
        { VK_NULL_HANDLE, 0, VK_WHOLE_SIZE }, { S.mapb.buf, 0, VK_WHOLE_SIZE },
        { S.texb.buf, 0, VK_WHOLE_SIZE }, { S.sprb.buf, 0, VK_WHOLE_SIZE } };
    VkWriteDescriptorSet wds[4];
    memset(wds, 0, sizeof wds);
    for (int i = 1; i < 4; i++) {
        wds[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        wds[i].dstSet = S.ds; wds[i].dstBinding = (uint32_t)i;
        wds[i].descriptorCount = 1; wds[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        wds[i].pBufferInfo = &dbi[i];
    }
    vkUpdateDescriptorSets(S.dev, 3, wds + 1, 0, NULL);

    S.mode = 0;
    if (!make_frame_bufs()) { rv_shutdown(); return 0; }

    /* defaults */
    S.camX = 1.5f; S.camY = 1.5f; S.camAng = 0;
    S.fogDist = 14.0f; S.fogColor = 0xFF0C0E12u; S.shadeSides = 1;
    S.ready = 1;
    seterr("no error", VK_SUCCESS);
    return 1;
}

/* ---------------- scene setup ---------------- */

/* three byte arrays of mw*mh texture ids (0 = empty / none) */
void rv_set_map(const uint8_t *walls, const uint8_t *floors, const uint8_t *ceils) {
    if (!S.ready) return;
    int n = S.mw * S.mh;
    for (int i = 0; i < n; i++)
        S.cells[i] = (uint32_t)(walls ? walls[i] : 0) | ((uint32_t)(floors ? floors[i] : 0) << 8) |
                     ((uint32_t)(ceils ? ceils[i] : 0) << 16);
    S.mapDirty = 1;
}

void rv_set_cell(int cx, int cy, int wall) {
    if (!S.ready || cx < 0 || cy < 0 || cx >= S.mw || cy >= S.mh) return;
    uint32_t *c = &S.cells[cy * S.mw + cx];
    *c = (*c & 0xFFFFFF00u) | ((uint32_t)wall & 255u);
    S.mapDirty = 1;
}

/* id 1..64, pixels = 64*64 _Unsigned Long (&HAARRGGBB). Alpha 0 = transparent in sprites. */
void rv_set_texture(int id, const uint32_t *pixels) {
    if (!S.ready || id < 1 || id > MAXTEX || !pixels) return;
    memcpy(S.tex + (size_t)(id - 1) * TEXPIX, pixels, TEXPIX * 4);
    if (id > S.nTex) S.nTex = id;
    if (id < S.texLo) S.texLo = id;
    if (id > S.texHi) S.texHi = id;
    S.texDirty = 1;
}

/* count sprites, 4 Singles each: x, y, texture id, scale */
void rv_set_sprites(const float *data, int count) {
    if (!S.ready) return;
    if (count < 0) count = 0;
    if (count > MAXSPR) count = MAXSPR;
    if (count && data) memcpy(S.sprb.map, data, (size_t)count * 16);
    flush_buf(&S.sprb);
    S.nSpr = data ? count : 0;
}

void rv_camera(float x, float y, float ang) { S.camX = x; S.camY = y; S.camAng = ang; }

void rv_params(float fogDist, uint32_t fogColor, int shadeSides) {
    S.fogDist = fogDist; S.fogColor = fogColor; S.shadeSides = shadeSides;
}

/* ---------------- frame ---------------- */

/* renders one frame into pixels (w*h _Unsigned Long, e.g. _MEMIMAGE(screen).OFFSET).
 * Returns 1 on success, 0 on failure. */
int rv_frame(uint32_t *pixels) {
    if (!S.ready) { seterr("rv_init has not succeeded", VK_SUCCESS); return 0; }
    double t0 = now_ms();

    PushC pc;
    memset(&pc, 0, sizeof pc);
    float dx = cosf(S.camAng), dy = sinf(S.camAng);
    pc.pos[0] = S.camX; pc.pos[1] = S.camY;
    pc.dir[0] = dx; pc.dir[1] = dy;
    /* 66 degree field of view, corrected for the screen's aspect ratio */
    float fovScale = 0.66f * ((float)S.w / (float)S.h) / (4.0f / 3.0f);
    pc.plane[0] = -dy * fovScale; pc.plane[1] = dx * fovScale;
    pc.w = S.w; pc.h = S.h; pc.mw = S.mw; pc.mh = S.mh;
    pc.fogDist = S.fogDist; pc.fogColor = S.fogColor; pc.shadeSides = S.shadeSides;
    pc.nSpr = S.nSpr; pc.nTex = S.nTex;

    begin_cb();
    record_uploads();       /* map/texture changes, in this same submit, with a barrier */
    int direct = (S.mode >= 2);
    if (S.tsValid) {
        vkCmdResetQueryPool(S.cb, S.qpool, 0, 3);
        vkCmdWriteTimestamp(S.cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, S.qpool, 0);
    }
    vkCmdBindPipeline(S.cb, VK_PIPELINE_BIND_POINT_COMPUTE, S.pipe);
    vkCmdBindDescriptorSets(S.cb, VK_PIPELINE_BIND_POINT_COMPUTE, S.pl, 0, 1, &S.ds, 0, NULL);
    vkCmdPushConstants(S.cb, S.pl, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof pc, &pc);
    vkCmdDispatch(S.cb, (uint32_t)(S.w + 7) / 8, (uint32_t)(S.h + 7) / 8, 1);

    VkBufferMemoryBarrier bar = { VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER };
    bar.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
    bar.dstAccessMask = direct ? VK_ACCESS_HOST_READ_BIT : VK_ACCESS_TRANSFER_READ_BIT;
    bar.srcQueueFamilyIndex = bar.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    bar.buffer = S.out.buf; bar.size = VK_WHOLE_SIZE;
    vkCmdPipelineBarrier(S.cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                         direct ? VK_PIPELINE_STAGE_HOST_BIT : VK_PIPELINE_STAGE_TRANSFER_BIT,
                         0, 0, NULL, 1, &bar, 0, NULL);
    if (S.tsValid) vkCmdWriteTimestamp(S.cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, S.qpool, 1);

    if (!direct) {
        VkBufferCopy c = { 0, 0, S.out.size };
        vkCmdCopyBuffer(S.cb, S.out.buf, S.readback.buf, 1, &c);
        VkBufferMemoryBarrier hb = { VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER };
        hb.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        hb.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
        hb.srcQueueFamilyIndex = hb.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        hb.buffer = S.readback.buf; hb.size = VK_WHOLE_SIZE;
        vkCmdPipelineBarrier(S.cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
                             0, 0, NULL, 1, &hb, 0, NULL);
    }
    if (S.tsValid) vkCmdWriteTimestamp(S.cb, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, S.qpool, 2);
    vkEndCommandBuffer(S.cb);

    double t1 = now_ms();
    if (!submit_wait()) return 0;
    double t2 = now_ms();

    Buf *src = direct ? &S.out : &S.readback;
    invalidate_buf(src);
    if (pixels) memcpy(pixels, src->map, (size_t)S.out.size);
    double t3 = now_ms();

    if (S.tsValid) {
        uint64_t ts[3] = { 0, 0, 0 };
        if (vkGetQueryPoolResults(S.dev, S.qpool, 0, 3, sizeof ts, ts, sizeof(uint64_t),
                                  VK_QUERY_RESULT_64_BIT) == VK_SUCCESS && ts[1] >= ts[0] && ts[2] >= ts[1]) {
            S.gpuMs = (float)((double)(ts[1] - ts[0]) * S.tsPeriod / 1e6);
            S.copyMs = (float)((double)(ts[2] - ts[1]) * S.tsPeriod / 1e6);
        }
    }
    S.waitMs = (float)(t2 - t1);
    S.memcpyMs = (float)(t3 - t2);
    S.hostMs = (float)(t3 - t0);
    return 1;
}

/* gpuMs = shader time on the GPU, hostMs = whole rv_frame call incl. readback */
void rv_stats(float *gpuMs, float *hostMs) {
    if (gpuMs) *gpuMs = S.gpuMs;
    if (hostMs) *hostMs = S.hostMs;
}

/* detailed timing of the last frame, all in ms:
 * shader = compute on the GPU, copy = GPU copy to system RAM (0 in modes 2/3),
 * wait = submit until the GPU signalled done, cpu = memcpy into the QB64 screen */
void rv_stats2(float *shaderMs, float *copyMs, float *waitMs, float *cpuMs) {
    if (shaderMs) *shaderMs = S.gpuMs;
    if (copyMs) *copyMs = S.copyMs;
    if (waitMs) *waitMs = S.waitMs;
    if (cpuMs) *cpuMs = S.memcpyMs;
}

void rv_last_error(char *buf, int len) {
    if (!buf || len <= 0) return;
    int n = (int)strlen(g_err);
    for (int i = 0; i < len; i++) buf[i] = (i < n) ? g_err[i] : ' ';
}

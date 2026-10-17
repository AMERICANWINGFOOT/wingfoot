/* scopevk.c -- QBScopeVK: Vulkan compute oscilloscope library for QB64-PE
 * (libscopevk.so)
 *
 * Integrates up to millions of strange-attractor particles on the GPU,
 * splats their paths into an HDR phosphor buffer, applies CRT decay and
 * bloom, and hands QB64 a finished 32-bit frame.
 *
 * Frame path (one command buffer, one submit):
 *   [clear] -> [seed] -> step+splat -> tonemap -> decay
 *   -> copy frame to a host-cached readback buffer -> memcpy into QB64's image
 * Everything else (particles, phosphor) stays in VRAM.
 *
 * Build:  ./build.sh
 *   (gcc -O2 -shared -fPIC scopevk.c -o libscopevk.so -l:libvulkan.so.1 -lm)
 * Needs libvulkan-dev to build; only libvulkan1 to run.
 *
 * GPU choice: sv_init(-1, ...) picks the first discrete GPU, else the first
 * device. Environment variable SCOPEVK_GPU=<index> overrides that.
 */
#include <vulkan/vulkan.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "scopevk_spv.h"

#define API __attribute__((visibility("default")))
#define MAXPHYS 16
#define TOTAL_ENERGY 134217728.0   /* 2^27 phosphor units laid down per frame */

/* must match the push_constant block in scopevk.comp (128 bytes) */
typedef struct {
    int32_t mode, att, n, steps;
    float a, b, c, dt;
    float x0, y0, z0, spread;
    float vcx, vcy, vhx, vhy;
    int32_t chH, chV, w, h;
    int32_t border, rk4;
    uint32_t frame, seed;
    float decay, gain, bloom;
    int32_t colorMode;
    uint32_t splat;
    float norm;
    int32_t pad0, pad1;
} PushC;

typedef struct {
    VkBuffer buf;
    VkDeviceMemory mem;
    VkDeviceSize size;
    void *map;
    int coherent;
} Buf;

static struct {
    VkInstance inst;
    uint32_t nphys;
    VkPhysicalDevice phys[MAXPHYS];

    int ready;
    int devIndex;
    VkPhysicalDevice pd;
    VkDevice dev;
    VkQueue q;
    uint32_t qfam;
    VkCommandPool cpool;
    VkCommandBuffer cb;
    VkFence fence;
    VkQueryPool qpool;
    int tsValid;
    float tsPeriod;

    VkDescriptorSetLayout dsl;
    VkDescriptorPool dpool;
    VkDescriptorSet ds;
    VkPipelineLayout pl;
    VkShaderModule sm;
    VkPipeline pipe;

    Buf parts, accI, accH, out, readback, stats;
    int w, h, maxN;

    /* host-side state */
    PushC pc;
    int n;
    int pendingClear, pendingSpawn;
    uint32_t frame;
    double lastTotal;   /* particles * steps of the last running frame */
    float gpuMs, hostMs;
} S;

static char gErr[256];

static void seterr(const char *msg, VkResult r) {
    if (r != VK_SUCCESS) snprintf(gErr, sizeof gErr, "%s (VkResult %d)", msg, (int)r);
    else snprintf(gErr, sizeof gErr, "%s", msg);
}

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1.0e6;
}

/* ---------------------------------------------------------------- instance */

static int ensure_instance(void) {
    if (S.inst) return 1;
    VkApplicationInfo ai = { VK_STRUCTURE_TYPE_APPLICATION_INFO };
    ai.pApplicationName = "QBScopeVK";
    ai.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    ici.pApplicationInfo = &ai;
    VkResult r = vkCreateInstance(&ici, NULL, &S.inst);
    if (r != VK_SUCCESS) { S.inst = NULL; seterr("vkCreateInstance failed - is a Vulkan driver installed?", r); return 0; }
    S.nphys = MAXPHYS;
    r = vkEnumeratePhysicalDevices(S.inst, &S.nphys, S.phys);
    if ((r != VK_SUCCESS && r != VK_INCOMPLETE) || S.nphys == 0) {
        seterr("no Vulkan devices found", r);
        vkDestroyInstance(S.inst, NULL); S.inst = NULL; S.nphys = 0;
        return 0;
    }
    return 1;
}

static int pick_device(void) {
    const char *env = getenv("SCOPEVK_GPU");
    if (env && *env) {
        int i = atoi(env);
        if (i >= 0 && (uint32_t)i < S.nphys) return i;
    }
    for (uint32_t i = 0; i < S.nphys; i++) {
        VkPhysicalDeviceProperties p;
        vkGetPhysicalDeviceProperties(S.phys[i], &p);
        if (p.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) return (int)i;
    }
    return 0;
}

API int sv_device_count(void) {
    if (!ensure_instance()) return 0;
    return (int)S.nphys;
}

API void sv_device_name(int idx, char *buf, int buflen) {
    if (!buf || buflen <= 0) return;
    buf[0] = 0;
    if (!ensure_instance() || idx < 0 || (uint32_t)idx >= S.nphys) return;
    VkPhysicalDeviceProperties p;
    vkGetPhysicalDeviceProperties(S.phys[idx], &p);
    snprintf(buf, (size_t)buflen, "%s", p.deviceName);
}

API int sv_current_device(void) { return S.ready ? S.devIndex : -1; }

API void sv_last_error(char *buf, int buflen) {
    if (!buf || buflen <= 0) return;
    snprintf(buf, (size_t)buflen, "%s", gErr);
}

/* ---------------------------------------------------------------- buffers */

static int find_mem(uint32_t bits, VkMemoryPropertyFlags want, VkMemoryPropertyFlags *got) {
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(S.pd, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) {
            if (got) *got = mp.memoryTypes[i].propertyFlags;
            return (int)i;
        }
    return -1;
}

/* tries each wanted flag set in turn */
static int make_buf(Buf *b, VkDeviceSize size, VkBufferUsageFlags usage,
                    const VkMemoryPropertyFlags *wants, int nwants, int mapIt) {
    memset(b, 0, sizeof *b);
    b->size = size;
    VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    bci.size = size; bci.usage = usage; bci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    VkResult r = vkCreateBuffer(S.dev, &bci, NULL, &b->buf);
    if (r != VK_SUCCESS) { b->buf = VK_NULL_HANDLE; seterr("vkCreateBuffer failed", r); return 0; }
    VkMemoryRequirements mr;
    vkGetBufferMemoryRequirements(S.dev, b->buf, &mr);
    int type = -1;
    VkMemoryPropertyFlags got = 0;
    for (int i = 0; i < nwants && type < 0; i++) type = find_mem(mr.memoryTypeBits, wants[i], &got);
    if (type < 0) { seterr("no suitable memory type", VK_SUCCESS); return 0; }
    VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    mai.allocationSize = mr.size; mai.memoryTypeIndex = (uint32_t)type;
    r = vkAllocateMemory(S.dev, &mai, NULL, &b->mem);
    if (r != VK_SUCCESS) { b->mem = VK_NULL_HANDLE; seterr("vkAllocateMemory failed (out of VRAM?)", r); return 0; }
    vkBindBufferMemory(S.dev, b->buf, b->mem, 0);
    b->coherent = (got & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0;
    if (mapIt) {
        r = vkMapMemory(S.dev, b->mem, 0, VK_WHOLE_SIZE, 0, &b->map);
        if (r != VK_SUCCESS) { b->map = NULL; seterr("vkMapMemory failed", r); return 0; }
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

/* ---------------------------------------------------------------- init */

API void sv_shutdown(void) {
    if (S.dev) {
        vkDeviceWaitIdle(S.dev);
        free_buf(&S.parts); free_buf(&S.accI); free_buf(&S.accH);
        free_buf(&S.out); free_buf(&S.readback); free_buf(&S.stats);
        if (S.pipe) vkDestroyPipeline(S.dev, S.pipe, NULL);
        if (S.sm) vkDestroyShaderModule(S.dev, S.sm, NULL);
        if (S.pl) vkDestroyPipelineLayout(S.dev, S.pl, NULL);
        if (S.dpool) vkDestroyDescriptorPool(S.dev, S.dpool, NULL);
        if (S.dsl) vkDestroyDescriptorSetLayout(S.dev, S.dsl, NULL);
        if (S.qpool) vkDestroyQueryPool(S.dev, S.qpool, NULL);
        if (S.fence) vkDestroyFence(S.dev, S.fence, NULL);
        if (S.cpool) vkDestroyCommandPool(S.dev, S.cpool, NULL);
        vkDestroyDevice(S.dev, NULL);
    }
    S.dev = NULL; S.pipe = VK_NULL_HANDLE; S.sm = VK_NULL_HANDLE; S.pl = VK_NULL_HANDLE;
    S.dpool = VK_NULL_HANDLE; S.dsl = VK_NULL_HANDLE; S.qpool = VK_NULL_HANDLE;
    S.fence = VK_NULL_HANDLE; S.cpool = VK_NULL_HANDLE; S.cb = VK_NULL_HANDLE;
    S.ready = 0;
}

/* Returns 1 on success, 0 on failure (see sv_last_error).
 * dev = -1 picks automatically. w, h = scope image size. maxN = most particles. */
API int sv_init(int dev, int w, int h, int maxN) {
    VkResult r;
    sv_shutdown();
    if (w < 16 || h < 16 || maxN < 1) { seterr("bad size arguments", VK_SUCCESS); return 0; }
    if (!ensure_instance()) return 0;

    if (dev < 0 || (uint32_t)dev >= S.nphys) dev = pick_device();
    S.devIndex = dev;
    S.pd = S.phys[dev];

    uint32_t nq = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(S.pd, &nq, NULL);
    VkQueueFamilyProperties qf[32];
    if (nq > 32) nq = 32;
    vkGetPhysicalDeviceQueueFamilyProperties(S.pd, &nq, qf);
    int fam = -1;
    for (uint32_t i = 0; i < nq; i++)
        if (qf[i].queueFlags & VK_QUEUE_COMPUTE_BIT) { fam = (int)i; break; }
    if (fam < 0) { seterr("device has no compute queue", VK_SUCCESS); return 0; }
    S.qfam = (uint32_t)fam;
    S.tsValid = qf[fam].timestampValidBits != 0;

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
    qci.queueFamilyIndex = S.qfam; qci.queueCount = 1; qci.pQueuePriorities = &prio;
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
    dci.queueCreateInfoCount = 1; dci.pQueueCreateInfos = &qci;
    r = vkCreateDevice(S.pd, &dci, NULL, &S.dev);
    if (r != VK_SUCCESS) { S.dev = NULL; seterr("vkCreateDevice failed", r); return 0; }
    vkGetDeviceQueue(S.dev, S.qfam, 0, &S.q);

    VkPhysicalDeviceProperties pr;
    vkGetPhysicalDeviceProperties(S.pd, &pr);
    S.tsPeriod = pr.limits.timestampPeriod;
    if (pr.limits.maxPushConstantsSize < sizeof(PushC)) {
        seterr("device push-constant space too small", VK_SUCCESS); sv_shutdown(); return 0;
    }

    VkCommandPoolCreateInfo cpi = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
    cpi.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    cpi.queueFamilyIndex = S.qfam;
    r = vkCreateCommandPool(S.dev, &cpi, NULL, &S.cpool);
    if (r != VK_SUCCESS) { seterr("vkCreateCommandPool failed", r); sv_shutdown(); return 0; }
    VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    cai.commandPool = S.cpool; cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; cai.commandBufferCount = 1;
    vkAllocateCommandBuffers(S.dev, &cai, &S.cb);
    VkFenceCreateInfo fci = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    vkCreateFence(S.dev, &fci, NULL, &S.fence);
    if (S.tsValid) {
        VkQueryPoolCreateInfo qpi = { VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO };
        qpi.queryType = VK_QUERY_TYPE_TIMESTAMP; qpi.queryCount = 2;
        if (vkCreateQueryPool(S.dev, &qpi, NULL, &S.qpool) != VK_SUCCESS) { S.qpool = VK_NULL_HANDLE; S.tsValid = 0; }
    }

    /* buffers */
    S.w = w; S.h = h; S.maxN = maxN;
    VkDeviceSize pix = (VkDeviceSize)w * h * 4;
    const VkMemoryPropertyFlags vram[] = { VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, 0 };
    const VkMemoryPropertyFlags rb[] = {
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_CACHED_BIT,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT };
    const VkMemoryPropertyFlags hv[] = {
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT };
    VkBufferUsageFlags st = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    if (!make_buf(&S.parts, (VkDeviceSize)maxN * 16, st, vram, 2, 0) ||
        !make_buf(&S.accI, pix, st, vram, 2, 0) ||
        !make_buf(&S.accH, pix, st, vram, 2, 0) ||
        !make_buf(&S.out, pix, st | VK_BUFFER_USAGE_TRANSFER_SRC_BIT, vram, 2, 0) ||
        !make_buf(&S.readback, pix, VK_BUFFER_USAGE_TRANSFER_DST_BIT, rb, 2, 1) ||
        !make_buf(&S.stats, 16, st, hv, 1, 1)) { sv_shutdown(); return 0; }
    memset(S.stats.map, 0, 16);

    /* descriptors: 5 storage buffers */
    VkDescriptorSetLayoutBinding bnd[5];
    memset(bnd, 0, sizeof bnd);
    for (int i = 0; i < 5; i++) {
        bnd[i].binding = (uint32_t)i;
        bnd[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        bnd[i].descriptorCount = 1;
        bnd[i].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    }
    VkDescriptorSetLayoutCreateInfo dli = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO };
    dli.bindingCount = 5; dli.pBindings = bnd;
    vkCreateDescriptorSetLayout(S.dev, &dli, NULL, &S.dsl);
    VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 5 };
    VkDescriptorPoolCreateInfo dpi = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO };
    dpi.maxSets = 1; dpi.poolSizeCount = 1; dpi.pPoolSizes = &ps;
    vkCreateDescriptorPool(S.dev, &dpi, NULL, &S.dpool);
    VkDescriptorSetAllocateInfo dai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO };
    dai.descriptorPool = S.dpool; dai.descriptorSetCount = 1; dai.pSetLayouts = &S.dsl;
    r = vkAllocateDescriptorSets(S.dev, &dai, &S.ds);
    if (r != VK_SUCCESS) { seterr("vkAllocateDescriptorSets failed", r); sv_shutdown(); return 0; }
    Buf *bufs[5] = { &S.parts, &S.accI, &S.accH, &S.out, &S.stats };
    VkDescriptorBufferInfo dbi[5];
    VkWriteDescriptorSet wr[5];
    memset(wr, 0, sizeof wr);
    for (int i = 0; i < 5; i++) {
        dbi[i].buffer = bufs[i]->buf; dbi[i].offset = 0; dbi[i].range = VK_WHOLE_SIZE;
        wr[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        wr[i].dstSet = S.ds; wr[i].dstBinding = (uint32_t)i; wr[i].descriptorCount = 1;
        wr[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER; wr[i].pBufferInfo = &dbi[i];
    }
    vkUpdateDescriptorSets(S.dev, 5, wr, 0, NULL);

    /* pipeline */
    VkPushConstantRange pcr = { VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(PushC) };
    VkPipelineLayoutCreateInfo pli = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    pli.setLayoutCount = 1; pli.pSetLayouts = &S.dsl;
    pli.pushConstantRangeCount = 1; pli.pPushConstantRanges = &pcr;
    vkCreatePipelineLayout(S.dev, &pli, NULL, &S.pl);
    VkShaderModuleCreateInfo smi = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
    smi.codeSize = scopevk_spv_size; smi.pCode = scopevk_spv;
    r = vkCreateShaderModule(S.dev, &smi, NULL, &S.sm);
    if (r != VK_SUCCESS) { seterr("vkCreateShaderModule failed", r); sv_shutdown(); return 0; }
    VkComputePipelineCreateInfo cpci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO };
    cpci.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    cpci.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    cpci.stage.module = S.sm; cpci.stage.pName = "main";
    cpci.layout = S.pl;
    r = vkCreateComputePipelines(S.dev, VK_NULL_HANDLE, 1, &cpci, NULL, &S.pipe);
    if (r != VK_SUCCESS) { S.pipe = VK_NULL_HANDLE; seterr("vkCreateComputePipelines failed", r); sv_shutdown(); return 0; }

    /* sensible defaults so a frame works before any setters */
    memset(&S.pc, 0, sizeof S.pc);
    S.pc.att = 2; S.pc.a = 10; S.pc.b = 28; S.pc.c = 8.0f / 3.0f; S.pc.dt = 0.005f; S.pc.rk4 = 1;
    S.pc.x0 = 1; S.pc.y0 = 1; S.pc.z0 = 1; S.pc.spread = 0.001f;
    S.pc.chH = 1; S.pc.chV = 3; S.pc.vcx = 0; S.pc.vcy = 25; S.pc.vhx = 25; S.pc.vhy = 25; S.pc.border = 30;
    S.pc.decay = 0.9f; S.pc.gain = 1.0f; S.pc.bloom = 0.5f;
    S.pc.w = w; S.pc.h = h;
    S.n = maxN < 65536 ? maxN : 65536;
    S.pendingClear = 1; S.pendingSpawn = 1;
    S.frame = 0; S.lastTotal = 0;
    S.ready = 1;
    gErr[0] = 0;
    return 1;
}

/* ---------------------------------------------------------------- setters */

API void sv_system(int att, float a, float b, float c, float dt, int rk4) {
    S.pc.att = att; S.pc.a = a; S.pc.b = b; S.pc.c = c; S.pc.dt = dt; S.pc.rk4 = rk4 ? 1 : 0;
}

/* chH/chV: 1 = x, 2 = y, 3 = z. cx/cy, hx/hy: centre and half-range of those
 * variables. border: pixels between the image edge and the graticule. */
API void sv_view(int chH, int chV, float cx, float cy, float hx, float hy, int border) {
    S.pc.chH = chH; S.pc.chV = chV;
    S.pc.vcx = cx; S.pc.vcy = cy;
    S.pc.vhx = hx != 0 ? hx : 1; S.pc.vhy = hy != 0 ? hy : 1;
    S.pc.border = border;
}

API void sv_beam(float decay, float gain, float bloom, int colorMode) {
    if (decay < 0) decay = 0;
    if (decay > 0.995f) decay = 0.995f;
    S.pc.decay = decay; S.pc.gain = gain; S.pc.bloom = bloom; S.pc.colorMode = colorMode;
}

/* Re-seed n particles in a cube of +/-spread around (x0, y0, z0); takes
 * effect on the next frame. The start point is also where runaways respawn. */
API void sv_spawn(int n, float x0, float y0, float z0, float spread) {
    if (n < 1) n = 1;
    if (n > S.maxN) n = S.maxN;
    S.n = n;
    S.pc.x0 = x0; S.pc.y0 = y0; S.pc.z0 = z0; S.pc.spread = spread;
    S.pendingSpawn = 1;
}

API void sv_clear(void) { S.pendingClear = 1; }

API int sv_runaways(void) {
    if (!S.ready) return 0;
    volatile uint32_t *st = (volatile uint32_t *)S.stats.map;
    int r = (int)st[0];
    st[0] = 0;
    return r;
}

API void sv_stats(float *gpuMs, float *hostMs) {
    if (gpuMs) *gpuMs = S.gpuMs;
    if (hostMs) *hostMs = S.hostMs;
}

/* ---------------------------------------------------------------- frame */

static void dispatch(int mode, uint32_t count) {
    S.pc.mode = mode;
    vkCmdPushConstants(S.cb, S.pl, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof S.pc, &S.pc);
    vkCmdDispatch(S.cb, (count + 255) / 256, 1, 1);
}

static void compute_barrier(void) {
    VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER };
    mb.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT | VK_ACCESS_SHADER_READ_BIT;
    mb.dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT;
    vkCmdPipelineBarrier(S.cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                         0, 1, &mb, 0, NULL, 0, NULL);
}

/* Advances every particle `steps` times (0 = frozen: no stepping, no decay),
 * then writes the w*h frame into pixels (e.g. _MEMIMAGE(img).OFFSET).
 * pixels may be NULL to skip the copy. Returns 1 on success, 0 on failure. */
API int sv_frame(int steps, uint32_t *pixels) {
    if (!S.ready) { seterr("sv_init has not succeeded", VK_SUCCESS); return 0; }
    double t0 = now_ms();
    uint32_t npix = (uint32_t)(S.w * S.h);

    if (steps < 0) steps = 0;
    if (steps > 0) S.lastTotal = (double)S.n * steps;
    double total = S.lastTotal > 0 ? S.lastTotal : (double)S.n;
    double sp = TOTAL_ENERGY / total;
    if (sp < 1) sp = 1;
    if (sp > 1048576) sp = 1048576;
    S.pc.splat = (uint32_t)sp;
    /* average phosphor energy per pixel at steady state, x10 because an
     * attractor lights only about a tenth of the screen */
    double avg = (double)S.pc.splat * total / ((double)npix * (1.0 - S.pc.decay));
    S.pc.norm = (float)(1.0 / (avg * 10.0));
    S.pc.n = S.n;
    S.pc.steps = steps;
    S.pc.frame = S.frame++;
    S.pc.seed = (uint32_t)(S.frame * 2654435761u);
    if (getenv("SCOPEVK_DEBUG") && S.frame % 30 == 1)
        fprintf(stderr, "scopevk f%u att%d abc %g %g %g dt %g rk4 %d | n %d steps %d | ch %d/%d c %g/%g h %g/%g brd %d"
                " | decay %g gain %g bloom %g col %d splat %u norm %g\n",
                S.pc.frame, S.pc.att, S.pc.a, S.pc.b, S.pc.c, S.pc.dt, S.pc.rk4, S.pc.n, S.pc.steps,
                S.pc.chH, S.pc.chV, S.pc.vcx, S.pc.vcy, S.pc.vhx, S.pc.vhy, S.pc.border,
                S.pc.decay, S.pc.gain, S.pc.bloom, S.pc.colorMode, S.pc.splat, S.pc.norm);

    vkResetCommandBuffer(S.cb, 0);
    VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(S.cb, &bi);
    if (S.tsValid) {
        vkCmdResetQueryPool(S.cb, S.qpool, 0, 2);
        vkCmdWriteTimestamp(S.cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, S.qpool, 0);
    }
    vkCmdBindPipeline(S.cb, VK_PIPELINE_BIND_POINT_COMPUTE, S.pipe);
    vkCmdBindDescriptorSets(S.cb, VK_PIPELINE_BIND_POINT_COMPUTE, S.pl, 0, 1, &S.ds, 0, NULL);

    if (S.pendingClear) { dispatch(4, npix); compute_barrier(); S.pendingClear = 0; }
    if (S.pendingSpawn) { dispatch(0, (uint32_t)S.n); compute_barrier(); S.pendingSpawn = 0; }
    if (steps > 0) { dispatch(1, (uint32_t)S.n); compute_barrier(); }
    dispatch(2, npix);
    compute_barrier();
    if (steps > 0) dispatch(3, npix);

    /* tonemap output -> readback */
    VkBufferMemoryBarrier bar = { VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER };
    bar.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
    bar.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    bar.srcQueueFamilyIndex = bar.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    bar.buffer = S.out.buf; bar.size = VK_WHOLE_SIZE;
    vkCmdPipelineBarrier(S.cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         0, 0, NULL, 1, &bar, 0, NULL);
    if (S.tsValid) vkCmdWriteTimestamp(S.cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, S.qpool, 1);
    VkBufferCopy c = { 0, 0, S.out.size };
    vkCmdCopyBuffer(S.cb, S.out.buf, S.readback.buf, 1, &c);
    VkBufferMemoryBarrier hb = { VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER };
    hb.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    hb.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
    hb.srcQueueFamilyIndex = hb.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    hb.buffer = S.readback.buf; hb.size = VK_WHOLE_SIZE;
    /* the stats counter is written by the shader and read by the host */
    VkMemoryBarrier hm = { VK_STRUCTURE_TYPE_MEMORY_BARRIER };
    hm.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
    hm.dstAccessMask = VK_ACCESS_HOST_READ_BIT | VK_ACCESS_HOST_WRITE_BIT;
    vkCmdPipelineBarrier(S.cb, VK_PIPELINE_STAGE_TRANSFER_BIT | VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                         VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &hm, 1, &hb, 0, NULL);
    vkEndCommandBuffer(S.cb);

    VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
    si.commandBufferCount = 1; si.pCommandBuffers = &S.cb;
    VkResult r = vkQueueSubmit(S.q, 1, &si, S.fence);
    if (r != VK_SUCCESS) { seterr("vkQueueSubmit failed", r); return 0; }
    r = vkWaitForFences(S.dev, 1, &S.fence, VK_TRUE, 5000000000ull);
    vkResetFences(S.dev, 1, &S.fence);
    if (r != VK_SUCCESS) { seterr("GPU frame timed out or device lost", r); return 0; }

    if (S.tsValid) {
        uint64_t ts[2];
        if (vkGetQueryPoolResults(S.dev, S.qpool, 0, 2, sizeof ts, ts, sizeof(uint64_t),
                                  VK_QUERY_RESULT_64_BIT) == VK_SUCCESS)
            S.gpuMs = (float)((double)(ts[1] - ts[0]) * S.tsPeriod / 1.0e6);
    }

    if (pixels) {
        if (!S.readback.coherent) {
            VkMappedMemoryRange mr = { VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE };
            mr.memory = S.readback.mem; mr.offset = 0; mr.size = VK_WHOLE_SIZE;
            vkInvalidateMappedMemoryRanges(S.dev, 1, &mr);
        }
        memcpy(pixels, S.readback.map, (size_t)S.out.size);
    }
    S.hostMs = (float)(now_ms() - t0);
    return 1;
}

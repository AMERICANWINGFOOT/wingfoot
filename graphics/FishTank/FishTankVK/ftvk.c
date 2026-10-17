// ftvk.c  -  Vulkan host side of libfishtank.so for QB64-PE
//
// Drop-in replacement for the CUDA build of fishtank.cu: same ft_* functions,
// same data layouts, same library name. FishTank.bas does not change.
//
// Runs on any Vulkan GPU: NVIDIA (GTX 745 / 1070 / 3050), Intel Arc, AMD.
//
// Pick the card with an environment variable (index from the list it prints):
//   FT_VK_DEVICE=1 ./FishTank
// Without it, the first discrete GPU is used.
//
// Build:  ./build.sh   (needs libvulkan-dev and glslang-tools)

#include <vulkan/vulkan.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "fishtank_spv.h"   // const uint32_t fishtank_spv[] - compiled fishtank.comp

#define FT_FISH_STRIDE 8
#define FT_BUB_STRIDE  3
#define FT_FOOD_STRIDE 2
#define FT_MAX_FISH    64
#define FT_MAX_BUB     512
#define FT_MAX_FOOD    128

typedef struct {
    VkBuffer       buf;
    VkDeviceMemory mem;
    void*          map;    // non-NULL if host visible and mapped
    VkDeviceSize   size;
    int            coherent;
} FtBuf;

typedef struct {
    int32_t W, H;
    float   t;
    int32_t nf, nb, nfd;
} FtPush;

static int  g_W = 0, g_H = 0;
static char g_err[256] = "";
static char g_dev[128] = "";

static VkInstance       g_inst = VK_NULL_HANDLE;
static VkPhysicalDevice g_phys = VK_NULL_HANDLE;
static VkDevice         g_devh = VK_NULL_HANDLE;
static VkQueue          g_queue = VK_NULL_HANDLE;
static uint32_t         g_qfam = 0;
static VkPhysicalDeviceMemoryProperties g_memProps;

static VkShaderModule        g_shader = VK_NULL_HANDLE;
static VkDescriptorSetLayout g_dsl = VK_NULL_HANDLE;
static VkPipelineLayout      g_pl = VK_NULL_HANDLE;
static VkPipeline            g_pipe = VK_NULL_HANDLE;
static VkDescriptorPool      g_dpool = VK_NULL_HANDLE;
static VkDescriptorSet       g_dset = VK_NULL_HANDLE;
static VkCommandPool         g_cpool = VK_NULL_HANDLE;
static VkCommandBuffer       g_cmd = VK_NULL_HANDLE;
static VkFence               g_fence = VK_NULL_HANDLE;

static FtBuf g_out, g_stage, g_fish, g_bub, g_food;
static int   g_useStage = 0;    // 1 = output lives in VRAM, copied to g_stage for readback

static int clampCount(int n, int mx) { return n < 0 ? 0 : (n > mx ? mx : n); }

static int vkFail(VkResult r, const char* where) {
    if (r == VK_SUCCESS) return 0;
    snprintf(g_err, sizeof(g_err), "%s failed (VkResult %d)", where, (int)r);
    return 1;
}

// Find a memory type with all 'want' flags; returns -1 if none.
static int findMem(uint32_t typeBits, VkMemoryPropertyFlags want) {
    for (uint32_t i = 0; i < g_memProps.memoryTypeCount; i++)
        if ((typeBits & (1u << i)) && (g_memProps.memoryTypes[i].propertyFlags & want) == want)
            return (int)i;
    return -1;
}

// Create a buffer, trying each flag set in order until one fits.
static int makeBuf(FtBuf* b, VkDeviceSize size, VkBufferUsageFlags usage,
                   const VkMemoryPropertyFlags* tries, int nTries, const char* name) {
    memset(b, 0, sizeof(*b));
    b->size = size;
    VkBufferCreateInfo bi = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    bi.size = size;
    bi.usage = usage;
    bi.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (vkFail(vkCreateBuffer(g_devh, &bi, NULL, &b->buf), name)) return 0;

    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(g_devh, b->buf, &req);
    int mt = -1;
    VkMemoryPropertyFlags got = 0;
    for (int i = 0; i < nTries && mt < 0; i++) { mt = findMem(req.memoryTypeBits, tries[i]); got = tries[i]; }
    if (mt < 0) { snprintf(g_err, sizeof(g_err), "%s: no suitable memory type", name); return 0; }

    VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    ai.allocationSize = req.size;
    ai.memoryTypeIndex = (uint32_t)mt;
    if (vkFail(vkAllocateMemory(g_devh, &ai, NULL, &b->mem), name)) return 0;
    if (vkFail(vkBindBufferMemory(g_devh, b->buf, b->mem, 0), name)) return 0;

    VkMemoryPropertyFlags actual = g_memProps.memoryTypes[mt].propertyFlags;
    b->coherent = (actual & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0;
    if (got & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)
        if (vkFail(vkMapMemory(g_devh, b->mem, 0, VK_WHOLE_SIZE, 0, &b->map), name)) return 0;
    return 1;
}

static void freeBuf(FtBuf* b) {
    if (!g_devh) return;
    if (b->map) vkUnmapMemory(g_devh, b->mem);
    if (b->buf) vkDestroyBuffer(g_devh, b->buf, NULL);
    if (b->mem) vkFreeMemory(g_devh, b->mem, NULL);
    memset(b, 0, sizeof(*b));
}

static const char* typeName(VkPhysicalDeviceType t) {
    switch (t) {
        case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU:   return "discrete";
        case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: return "integrated";
        case VK_PHYSICAL_DEVICE_TYPE_CPU:            return "cpu";
        default:                                     return "other";
    }
}

static int pickDevice(void) {
    uint32_t n = 0;
    vkEnumeratePhysicalDevices(g_inst, &n, NULL);
    if (n == 0) { snprintf(g_err, sizeof(g_err), "no Vulkan devices found"); return 0; }
    VkPhysicalDevice* list = (VkPhysicalDevice*)calloc(n, sizeof(VkPhysicalDevice));
    vkEnumeratePhysicalDevices(g_inst, &n, list);

    fprintf(stderr, "FishTank Vulkan devices:\n");
    int want = -1, firstDiscrete = -1;
    for (uint32_t i = 0; i < n; i++) {
        VkPhysicalDeviceProperties p;
        vkGetPhysicalDeviceProperties(list[i], &p);
        fprintf(stderr, "  %u: %s (%s)\n", i, p.deviceName, typeName(p.deviceType));
        if (firstDiscrete < 0 && p.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) firstDiscrete = (int)i;
    }
    const char* env = getenv("FT_VK_DEVICE");
    if (env && *env) {
        want = atoi(env);
        if (want < 0 || want >= (int)n) {
            snprintf(g_err, sizeof(g_err), "FT_VK_DEVICE=%d but only %u device(s)", want, n);
            free(list);
            return 0;
        }
    } else {
        want = firstDiscrete >= 0 ? firstDiscrete : 0;
    }
    g_phys = list[want];
    free(list);

    VkPhysicalDeviceProperties p;
    vkGetPhysicalDeviceProperties(g_phys, &p);
    snprintf(g_dev, sizeof(g_dev), "%.90s (Vulkan %u.%u)", p.deviceName,
             VK_VERSION_MAJOR(p.apiVersion), VK_VERSION_MINOR(p.apiVersion));
    fprintf(stderr, "  using %d: %s\n", want, p.deviceName);

    // compute-capable queue family
    uint32_t nq = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(g_phys, &nq, NULL);
    VkQueueFamilyProperties* qf = (VkQueueFamilyProperties*)calloc(nq, sizeof(VkQueueFamilyProperties));
    vkGetPhysicalDeviceQueueFamilyProperties(g_phys, &nq, qf);
    int found = -1;
    for (uint32_t i = 0; i < nq; i++)
        if (qf[i].queueFlags & VK_QUEUE_COMPUTE_BIT) { found = (int)i; break; }
    free(qf);
    if (found < 0) { snprintf(g_err, sizeof(g_err), "%.200s has no compute queue", p.deviceName); return 0; }
    g_qfam = (uint32_t)found;
    vkGetPhysicalDeviceMemoryProperties(g_phys, &g_memProps);
    return 1;
}

void ft_shutdown(void) {
    if (g_devh) vkDeviceWaitIdle(g_devh);
    freeBuf(&g_out); freeBuf(&g_stage); freeBuf(&g_fish); freeBuf(&g_bub); freeBuf(&g_food);
    if (g_devh) {
        if (g_fence)  vkDestroyFence(g_devh, g_fence, NULL);
        if (g_cpool)  vkDestroyCommandPool(g_devh, g_cpool, NULL);
        if (g_dpool)  vkDestroyDescriptorPool(g_devh, g_dpool, NULL);
        if (g_pipe)   vkDestroyPipeline(g_devh, g_pipe, NULL);
        if (g_pl)     vkDestroyPipelineLayout(g_devh, g_pl, NULL);
        if (g_dsl)    vkDestroyDescriptorSetLayout(g_devh, g_dsl, NULL);
        if (g_shader) vkDestroyShaderModule(g_devh, g_shader, NULL);
        vkDestroyDevice(g_devh, NULL);
    }
    if (g_inst) vkDestroyInstance(g_inst, NULL);
    g_fence = VK_NULL_HANDLE; g_cpool = VK_NULL_HANDLE; g_cmd = VK_NULL_HANDLE;
    g_dpool = VK_NULL_HANDLE; g_dset = VK_NULL_HANDLE; g_pipe = VK_NULL_HANDLE;
    g_pl = VK_NULL_HANDLE; g_dsl = VK_NULL_HANDLE; g_shader = VK_NULL_HANDLE;
    g_devh = VK_NULL_HANDLE; g_inst = VK_NULL_HANDLE; g_phys = VK_NULL_HANDLE;
    g_queue = VK_NULL_HANDLE;
    g_W = g_H = 0;
}

int ft_init(int w, int h) {
    ft_shutdown();
    if (w <= 0 || h <= 0) { snprintf(g_err, sizeof(g_err), "bad size %dx%d", w, h); return 0; }

    // ---- instance
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO };
    app.pApplicationName = "FishTank";
    app.apiVersion = VK_API_VERSION_1_0;
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    ici.pApplicationInfo = &app;
    if (vkFail(vkCreateInstance(&ici, NULL, &g_inst), "vkCreateInstance")) return 0;
    if (!pickDevice()) { ft_shutdown(); return 0; }

    // ---- device + queue
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
    qci.queueFamilyIndex = g_qfam;
    qci.queueCount = 1;
    qci.pQueuePriorities = &prio;
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    if (vkFail(vkCreateDevice(g_phys, &dci, NULL, &g_devh), "vkCreateDevice")) { ft_shutdown(); return 0; }
    vkGetDeviceQueue(g_devh, g_qfam, 0, &g_queue);

    // ---- buffers
    const VkMemoryPropertyFlags HV = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT;
    const VkMemoryPropertyFlags HC = VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    const VkMemoryPropertyFlags HCACHED = VK_MEMORY_PROPERTY_HOST_CACHED_BIT;
    const VkMemoryPropertyFlags DL = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
    VkDeviceSize frameBytes = (VkDeviceSize)w * h * 4;

    // Output: VRAM if the card has it, then copied to a host-cached staging buffer.
    // On integrated / CPU devices everything is one memory, so render straight into host memory.
    {
        VkPhysicalDeviceProperties p;
        vkGetPhysicalDeviceProperties(g_phys, &p);
        g_useStage = (p.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU);
    }
    if (g_useStage) {
        VkMemoryPropertyFlags outTry[] = { DL };
        VkMemoryPropertyFlags stTry[]  = { HV | HCACHED, HV | HC };
        if (!makeBuf(&g_out, frameBytes, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                     outTry, 1, "output buffer")) { ft_shutdown(); return 0; }
        if (!makeBuf(&g_stage, frameBytes, VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                     stTry, 2, "staging buffer")) { ft_shutdown(); return 0; }
    } else {
        VkMemoryPropertyFlags outTry[] = { HV | HCACHED, HV | HC };
        if (!makeBuf(&g_out, frameBytes, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                     outTry, 2, "output buffer")) { ft_shutdown(); return 0; }
    }
    // Scene inputs: small, host-visible, rewritten every frame.
    {
        VkMemoryPropertyFlags inTry[] = { HV | HC | DL, HV | HC };
        if (!makeBuf(&g_fish, FT_MAX_FISH * FT_FISH_STRIDE * sizeof(float), VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, inTry, 2, "fish buffer") ||
            !makeBuf(&g_bub,  FT_MAX_BUB  * FT_BUB_STRIDE  * sizeof(float), VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, inTry, 2, "bubble buffer") ||
            !makeBuf(&g_food, FT_MAX_FOOD * FT_FOOD_STRIDE * sizeof(float), VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, inTry, 2, "food buffer")) {
            ft_shutdown(); return 0;
        }
    }

    // ---- shader + pipeline
    VkShaderModuleCreateInfo smi = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
    smi.codeSize = sizeof(fishtank_spv);
    smi.pCode = fishtank_spv;
    if (vkFail(vkCreateShaderModule(g_devh, &smi, NULL, &g_shader), "vkCreateShaderModule")) { ft_shutdown(); return 0; }

    VkDescriptorSetLayoutBinding binds[4];
    memset(binds, 0, sizeof(binds));
    for (int i = 0; i < 4; i++) {
        binds[i].binding = (uint32_t)i;
        binds[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        binds[i].descriptorCount = 1;
        binds[i].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    }
    VkDescriptorSetLayoutCreateInfo dli = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO };
    dli.bindingCount = 4;
    dli.pBindings = binds;
    if (vkFail(vkCreateDescriptorSetLayout(g_devh, &dli, NULL, &g_dsl), "descriptor layout")) { ft_shutdown(); return 0; }

    VkPushConstantRange pcr = { VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(FtPush) };
    VkPipelineLayoutCreateInfo pli = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    pli.setLayoutCount = 1;
    pli.pSetLayouts = &g_dsl;
    pli.pushConstantRangeCount = 1;
    pli.pPushConstantRanges = &pcr;
    if (vkFail(vkCreatePipelineLayout(g_devh, &pli, NULL, &g_pl), "pipeline layout")) { ft_shutdown(); return 0; }

    VkComputePipelineCreateInfo cpi = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO };
    cpi.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    cpi.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    cpi.stage.module = g_shader;
    cpi.stage.pName = "main";
    cpi.layout = g_pl;
    if (vkFail(vkCreateComputePipelines(g_devh, VK_NULL_HANDLE, 1, &cpi, NULL, &g_pipe), "compute pipeline")) { ft_shutdown(); return 0; }

    // ---- descriptors
    VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 4 };
    VkDescriptorPoolCreateInfo dpi = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO };
    dpi.maxSets = 1;
    dpi.poolSizeCount = 1;
    dpi.pPoolSizes = &ps;
    if (vkFail(vkCreateDescriptorPool(g_devh, &dpi, NULL, &g_dpool), "descriptor pool")) { ft_shutdown(); return 0; }
    VkDescriptorSetAllocateInfo dsa = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO };
    dsa.descriptorPool = g_dpool;
    dsa.descriptorSetCount = 1;
    dsa.pSetLayouts = &g_dsl;
    if (vkFail(vkAllocateDescriptorSets(g_devh, &dsa, &g_dset), "descriptor set")) { ft_shutdown(); return 0; }

    FtBuf* bufs[4] = { &g_out, &g_fish, &g_bub, &g_food };
    VkDescriptorBufferInfo dbi[4];
    VkWriteDescriptorSet wr[4];
    memset(wr, 0, sizeof(wr));
    for (int i = 0; i < 4; i++) {
        dbi[i].buffer = bufs[i]->buf;
        dbi[i].offset = 0;
        dbi[i].range = VK_WHOLE_SIZE;
        wr[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        wr[i].dstSet = g_dset;
        wr[i].dstBinding = (uint32_t)i;
        wr[i].descriptorCount = 1;
        wr[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        wr[i].pBufferInfo = &dbi[i];
    }
    vkUpdateDescriptorSets(g_devh, 4, wr, 0, NULL);

    // ---- command buffer + fence
    VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
    cpci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    cpci.queueFamilyIndex = g_qfam;
    if (vkFail(vkCreateCommandPool(g_devh, &cpci, NULL, &g_cpool), "command pool")) { ft_shutdown(); return 0; }
    VkCommandBufferAllocateInfo cba = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    cba.commandPool = g_cpool;
    cba.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cba.commandBufferCount = 1;
    if (vkFail(vkAllocateCommandBuffers(g_devh, &cba, &g_cmd), "command buffer")) { ft_shutdown(); return 0; }
    VkFenceCreateInfo fci = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    if (vkFail(vkCreateFence(g_devh, &fci, NULL, &g_fence), "fence")) { ft_shutdown(); return 0; }

    g_W = w; g_H = h;
    g_err[0] = 0;
    return 1;
}

static void flushIfNeeded(FtBuf* b) {
    if (b->coherent || !b->map) return;
    VkMappedMemoryRange r = { VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE };
    r.memory = b->mem; r.offset = 0; r.size = VK_WHOLE_SIZE;
    vkFlushMappedMemoryRanges(g_devh, 1, &r);
}

static void invalidateIfNeeded(FtBuf* b) {
    if (b->coherent || !b->map) return;
    VkMappedMemoryRange r = { VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE };
    r.memory = b->mem; r.offset = 0; r.size = VK_WHOLE_SIZE;
    vkInvalidateMappedMemoryRanges(g_devh, 1, &r);
}

int ft_render(float t, const float* fish, int nf, const float* bub, int nb,
              const float* food, int nfd, void* outBGRA) {
    if (!g_W || !outBGRA) { snprintf(g_err, sizeof(g_err), "not initialised"); return 0; }
    nf  = clampCount(nf,  FT_MAX_FISH);
    nb  = clampCount(nb,  FT_MAX_BUB);
    nfd = clampCount(nfd, FT_MAX_FOOD);

    if (nf)  memcpy(g_fish.map, fish, (size_t)nf  * FT_FISH_STRIDE * sizeof(float));
    if (nb)  memcpy(g_bub.map,  bub,  (size_t)nb  * FT_BUB_STRIDE  * sizeof(float));
    if (nfd) memcpy(g_food.map, food, (size_t)nfd * FT_FOOD_STRIDE * sizeof(float));
    flushIfNeeded(&g_fish); flushIfNeeded(&g_bub); flushIfNeeded(&g_food);

    FtPush pc;
    pc.W = g_W; pc.H = g_H; pc.t = t; pc.nf = nf; pc.nb = nb; pc.nfd = nfd;

    if (vkFail(vkResetCommandBuffer(g_cmd, 0), "reset command buffer")) return 0;
    VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if (vkFail(vkBeginCommandBuffer(g_cmd, &bi), "begin command buffer")) return 0;

    // make the host writes to the scene buffers visible to the shader
    VkMemoryBarrier hb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER };
    hb.srcAccessMask = VK_ACCESS_HOST_WRITE_BIT;
    hb.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    vkCmdPipelineBarrier(g_cmd, VK_PIPELINE_STAGE_HOST_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                         0, 1, &hb, 0, NULL, 0, NULL);

    vkCmdBindPipeline(g_cmd, VK_PIPELINE_BIND_POINT_COMPUTE, g_pipe);
    vkCmdBindDescriptorSets(g_cmd, VK_PIPELINE_BIND_POINT_COMPUTE, g_pl, 0, 1, &g_dset, 0, NULL);
    vkCmdPushConstants(g_cmd, g_pl, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(pc), &pc);
    vkCmdDispatch(g_cmd, (uint32_t)(g_W + 15) / 16, (uint32_t)(g_H + 15) / 16, 1);

    VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER };
    if (g_useStage) {
        mb.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
        mb.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        vkCmdPipelineBarrier(g_cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                             0, 1, &mb, 0, NULL, 0, NULL);
        VkBufferCopy cp = { 0, 0, g_out.size };
        vkCmdCopyBuffer(g_cmd, g_out.buf, g_stage.buf, 1, &cp);
        mb.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        mb.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
        vkCmdPipelineBarrier(g_cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
                             0, 1, &mb, 0, NULL, 0, NULL);
    } else {
        mb.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
        mb.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
        vkCmdPipelineBarrier(g_cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
                             0, 1, &mb, 0, NULL, 0, NULL);
    }
    if (vkFail(vkEndCommandBuffer(g_cmd), "end command buffer")) return 0;

    VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
    si.commandBufferCount = 1;
    si.pCommandBuffers = &g_cmd;
    if (vkFail(vkResetFences(g_devh, 1, &g_fence), "reset fence")) return 0;
    if (vkFail(vkQueueSubmit(g_queue, 1, &si, g_fence), "vkQueueSubmit")) return 0;
    if (vkFail(vkWaitForFences(g_devh, 1, &g_fence, VK_TRUE, 2000000000ull), "wait for frame")) return 0;

    FtBuf* src = g_useStage ? &g_stage : &g_out;
    invalidateIfNeeded(src);
    memcpy(outBGRA, src->map, (size_t)g_W * g_H * 4);
    return 1;
}

// Copies a NUL-terminated message into a QB64 fixed-length string buffer.
void ft_last_error(char* buf, int n) { if (buf && n > 0) { strncpy(buf, g_err, n - 1); buf[n - 1] = 0; } }
void ft_device_name(char* buf, int n) { if (buf && n > 0) { strncpy(buf, g_dev, n - 1); buf[n - 1] = 0; } }

// Same formula as the shader's sandTop(), so fish and food sit on the sand the GPU draws.
float ft_sand_top(float x, int h) {
    float H = (float)h;
    return H * 0.84f + sinf(x * 0.004f) * H * 0.025f + sinf(x * 0.011f + 1.3f) * H * 0.012f;
}

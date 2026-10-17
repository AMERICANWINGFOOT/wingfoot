/* vortexvk.c -- VortexVK: headless Vulkan compute renderer for QB64-PE
 *
 * Builds one compute pipeline (vortex.comp, embedded as SPIR-V in
 * vortex_spv.h), renders into a host-visible storage buffer and copies
 * the BGRA pixels straight into a QB64 image's memory.
 *
 * Error codes from vvk_init:
 *   -1 vkCreateInstance        -2 no Vulkan GPU found
 *   -3 no compute queue        -4 vkCreateDevice
 *   -5 buffer create           -6 no host-visible memory type
 *   -7 memory alloc/map        -8 shader/pipeline create
 *   -9 descriptor/command setup
 */
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

#include "libvortexvk.h"
#include "vortex_spv.h"

typedef struct {
    int32_t w, h;
    float t, zpos, bass, mids, treb, flash, twist, level, pad0, pad1;
    float bands[16];
} PushC;

static VkInstance            inst;
static VkPhysicalDevice      pdev;
static VkDevice              dev;
static VkQueue               queue;
static uint32_t              qfam;
static VkBuffer              buf;
static VkDeviceMemory        mem;
static void                 *mapped;
static int                   coherent;
static VkDescriptorSetLayout dsl;
static VkPipelineLayout      playout;
static VkShaderModule        smod;
static VkPipeline            pipe;
static VkDescriptorPool      dpool;
static VkDescriptorSet       dset;
static VkCommandPool         cpool;
static VkCommandBuffer       cmd;
static VkFence               fence;

static int   W, H, ready;
static float lastMs;
static float bandv[16];
static char  devName[256] = "none";

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1.0e6;
}

static int find_mem(uint32_t bits, VkMemoryPropertyFlags want, VkMemoryPropertyFlags *got)
{
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(pdev, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++) {
        if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) {
            *got = mp.memoryTypes[i].propertyFlags;
            return (int)i;
        }
    }
    return -1;
}

int vvk_init(int w, int h, int devIndex)
{
    if (ready) vvk_shutdown();
    W = w; H = h;

    /* ---- instance ---------------------------------------------------- */
    VkApplicationInfo ai = { VK_STRUCTURE_TYPE_APPLICATION_INFO };
    ai.pApplicationName = "VortexVK";
    ai.apiVersion = VK_API_VERSION_1_0;
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    ici.pApplicationInfo = &ai;
    if (vkCreateInstance(&ici, NULL, &inst) != VK_SUCCESS) return -1;

    /* ---- physical device --------------------------------------------- */
    uint32_t n = 0;
    vkEnumeratePhysicalDevices(inst, &n, NULL);
    if (n == 0) return -2;
    VkPhysicalDevice *list = (VkPhysicalDevice *)malloc(n * sizeof(VkPhysicalDevice));
    vkEnumeratePhysicalDevices(inst, &n, list);

    int pick = -1;
    for (uint32_t i = 0; i < n; i++) {
        VkPhysicalDeviceProperties pp;
        vkGetPhysicalDeviceProperties(list[i], &pp);
        fprintf(stderr, "VortexVK: GPU %u = %s%s\n", i, pp.deviceName,
                pp.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU ? " (discrete)" : "");
        if (devIndex < 0 && pick < 0 && pp.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU)
            pick = (int)i;
    }
    if (devIndex >= 0 && devIndex < (int)n) pick = devIndex;
    if (pick < 0) pick = 0;
    pdev = list[pick];
    free(list);

    VkPhysicalDeviceProperties pp;
    vkGetPhysicalDeviceProperties(pdev, &pp);
    snprintf(devName, sizeof devName, "%s", pp.deviceName);
    fprintf(stderr, "VortexVK: using GPU %d = %s\n", pick, devName);

    /* ---- compute queue family ---------------------------------------- */
    uint32_t qn = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(pdev, &qn, NULL);
    VkQueueFamilyProperties *qp = (VkQueueFamilyProperties *)malloc(qn * sizeof *qp);
    vkGetPhysicalDeviceQueueFamilyProperties(pdev, &qn, qp);
    int qf = -1;
    for (uint32_t i = 0; i < qn; i++)
        if (qp[i].queueFlags & VK_QUEUE_COMPUTE_BIT) { qf = (int)i; break; }
    free(qp);
    if (qf < 0) return -3;
    qfam = (uint32_t)qf;

    /* ---- logical device ---------------------------------------------- */
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
    qci.queueFamilyIndex = qfam;
    qci.queueCount = 1;
    qci.pQueuePriorities = &prio;
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    if (vkCreateDevice(pdev, &dci, NULL, &dev) != VK_SUCCESS) return -4;
    vkGetDeviceQueue(dev, qfam, 0, &queue);

    /* ---- output buffer (host visible, cached if possible) ------------ */
    VkDeviceSize size = (VkDeviceSize)W * H * 4;
    VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    bci.size = size;
    bci.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    bci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (vkCreateBuffer(dev, &bci, NULL, &buf) != VK_SUCCESS) return -5;

    VkMemoryRequirements mr;
    vkGetBufferMemoryRequirements(dev, buf, &mr);
    VkMemoryPropertyFlags got = 0;
    int mt = find_mem(mr.memoryTypeBits,
                      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_CACHED_BIT, &got);
    if (mt < 0) mt = find_mem(mr.memoryTypeBits,
                      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &got);
    if (mt < 0) mt = find_mem(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, &got);
    if (mt < 0) return -6;
    coherent = (got & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0;

    VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    mai.allocationSize = mr.size;
    mai.memoryTypeIndex = (uint32_t)mt;
    if (vkAllocateMemory(dev, &mai, NULL, &mem) != VK_SUCCESS) return -7;
    vkBindBufferMemory(dev, buf, mem, 0);
    if (vkMapMemory(dev, mem, 0, VK_WHOLE_SIZE, 0, &mapped) != VK_SUCCESS) return -7;

    /* ---- pipeline ---------------------------------------------------- */
    VkDescriptorSetLayoutBinding b = { 0 };
    b.binding = 0;
    b.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    b.descriptorCount = 1;
    b.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    VkDescriptorSetLayoutCreateInfo dlci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO };
    dlci.bindingCount = 1;
    dlci.pBindings = &b;
    if (vkCreateDescriptorSetLayout(dev, &dlci, NULL, &dsl) != VK_SUCCESS) return -8;

    VkPushConstantRange pcr = { VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(PushC) };
    VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    plci.setLayoutCount = 1;
    plci.pSetLayouts = &dsl;
    plci.pushConstantRangeCount = 1;
    plci.pPushConstantRanges = &pcr;
    if (vkCreatePipelineLayout(dev, &plci, NULL, &playout) != VK_SUCCESS) return -8;

    VkShaderModuleCreateInfo smci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
    smci.codeSize = sizeof(vortex_spv);
    smci.pCode = vortex_spv;
    if (vkCreateShaderModule(dev, &smci, NULL, &smod) != VK_SUCCESS) return -8;

    VkComputePipelineCreateInfo cpci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO };
    cpci.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    cpci.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    cpci.stage.module = smod;
    cpci.stage.pName = "main";
    cpci.layout = playout;
    if (vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpci, NULL, &pipe) != VK_SUCCESS) return -8;

    /* ---- descriptor set ---------------------------------------------- */
    VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1 };
    VkDescriptorPoolCreateInfo dpci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO };
    dpci.maxSets = 1;
    dpci.poolSizeCount = 1;
    dpci.pPoolSizes = &ps;
    if (vkCreateDescriptorPool(dev, &dpci, NULL, &dpool) != VK_SUCCESS) return -9;

    VkDescriptorSetAllocateInfo dsai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO };
    dsai.descriptorPool = dpool;
    dsai.descriptorSetCount = 1;
    dsai.pSetLayouts = &dsl;
    if (vkAllocateDescriptorSets(dev, &dsai, &dset) != VK_SUCCESS) return -9;

    VkDescriptorBufferInfo dbi = { buf, 0, VK_WHOLE_SIZE };
    VkWriteDescriptorSet wds = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET };
    wds.dstSet = dset;
    wds.dstBinding = 0;
    wds.descriptorCount = 1;
    wds.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    wds.pBufferInfo = &dbi;
    vkUpdateDescriptorSets(dev, 1, &wds, 0, NULL);

    /* ---- command buffer + fence -------------------------------------- */
    VkCommandPoolCreateInfo cpi = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
    cpi.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    cpi.queueFamilyIndex = qfam;
    if (vkCreateCommandPool(dev, &cpi, NULL, &cpool) != VK_SUCCESS) return -9;

    VkCommandBufferAllocateInfo cbai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    cbai.commandPool = cpool;
    cbai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cbai.commandBufferCount = 1;
    if (vkAllocateCommandBuffers(dev, &cbai, &cmd) != VK_SUCCESS) return -9;

    VkFenceCreateInfo fci = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    if (vkCreateFence(dev, &fci, NULL, &fence) != VK_SUCCESS) return -9;

    ready = 1;
    return 1;
}

void vvk_set_band(int i, float v)
{
    if (i >= 0 && i < 16) bandv[i] = v;
}

int vvk_render(intptr_t dst, float t, float zpos, float bass, float mids,
               float treb, float flash, float twist, float level)
{
    if (!ready || dst == 0) return 0;
    double t0 = now_ms();

    PushC pc;
    pc.w = W; pc.h = H;
    pc.t = t; pc.zpos = zpos;
    pc.bass = bass; pc.mids = mids; pc.treb = treb;
    pc.flash = flash; pc.twist = twist; pc.level = level;
    pc.pad0 = pc.pad1 = 0.0f;
    memcpy(pc.bands, bandv, sizeof bandv);

    VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(cmd, &bi);
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, playout, 0, 1, &dset, 0, NULL);
    vkCmdPushConstants(cmd, playout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof pc, &pc);
    vkCmdDispatch(cmd, (uint32_t)(W + 15) / 16, (uint32_t)(H + 15) / 16, 1);

    VkBufferMemoryBarrier bmb = { VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER };
    bmb.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
    bmb.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
    bmb.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    bmb.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    bmb.buffer = buf;
    bmb.offset = 0;
    bmb.size = VK_WHOLE_SIZE;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
                         0, 0, NULL, 1, &bmb, 0, NULL);
    vkEndCommandBuffer(cmd);

    VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
    si.commandBufferCount = 1;
    si.pCommandBuffers = &cmd;
    vkResetFences(dev, 1, &fence);
    if (vkQueueSubmit(queue, 1, &si, fence) != VK_SUCCESS) return 0;
    vkWaitForFences(dev, 1, &fence, VK_TRUE, UINT64_MAX);

    if (!coherent) {
        VkMappedMemoryRange r = { VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE };
        r.memory = mem;
        r.offset = 0;
        r.size = VK_WHOLE_SIZE;
        vkInvalidateMappedMemoryRanges(dev, 1, &r);
    }
    memcpy((void *)dst, mapped, (size_t)W * H * 4);

    lastMs = (float)(now_ms() - t0);
    return 1;
}

float vvk_ms(void) { return lastMs; }

void vvk_devname(char *out, int maxlen)
{
    if (!out || maxlen < 1) return;
    snprintf(out, (size_t)maxlen, "%s", devName);
}

void vvk_shutdown(void)
{
    if (dev) vkDeviceWaitIdle(dev);
    if (fence)   { vkDestroyFence(dev, fence, NULL); fence = VK_NULL_HANDLE; }
    if (cpool)   { vkDestroyCommandPool(dev, cpool, NULL); cpool = VK_NULL_HANDLE; }
    if (dpool)   { vkDestroyDescriptorPool(dev, dpool, NULL); dpool = VK_NULL_HANDLE; }
    if (pipe)    { vkDestroyPipeline(dev, pipe, NULL); pipe = VK_NULL_HANDLE; }
    if (smod)    { vkDestroyShaderModule(dev, smod, NULL); smod = VK_NULL_HANDLE; }
    if (playout) { vkDestroyPipelineLayout(dev, playout, NULL); playout = VK_NULL_HANDLE; }
    if (dsl)     { vkDestroyDescriptorSetLayout(dev, dsl, NULL); dsl = VK_NULL_HANDLE; }
    if (mapped)  { vkUnmapMemory(dev, mem); mapped = NULL; }
    if (mem)     { vkFreeMemory(dev, mem, NULL); mem = VK_NULL_HANDLE; }
    if (buf)     { vkDestroyBuffer(dev, buf, NULL); buf = VK_NULL_HANDLE; }
    if (dev)     { vkDestroyDevice(dev, NULL); dev = VK_NULL_HANDLE; }
    if (inst)    { vkDestroyInstance(inst, NULL); inst = VK_NULL_HANDLE; }
    ready = 0;
}

// g3d_vk.cpp - GPU3D Vulkan back end: the same g3_ functions as g3d.cu, for any
// Vulkan GPU - AMD Radeon, Intel Arc / integrated, NVIDIA - on Linux or Windows.  (v1.1)
//
// One GPU does the whole frame with a compute shader (g3d_draw.comp, embedded
// as SPIR-V in g3d_draw_spv.h). The shape math matches g3d_math.h exactly.
//
// Which GPU: the first discrete card, else integrated, else anything Vulkan has.
// To choose, call g3_prefer_device("Radeon") before g3_init, or set the
// environment variable G3D_DEVICE to part of the card's name.
//
// Needs g3d_math.h, g3d_common.h and g3d_draw_spv.h in the same folder.
//
// Build on Linux (sudo apt install libvulkan-dev):
//   g++ -O2 -fPIC -shared -o libg3d.so g3d_vk.cpp -lvulkan
//
// Build on Windows (Vulkan SDK installed, MinGW g++):
//   g++ -O2 -shared -o g3d.dll g3d_vk.cpp -I"%VULKAN_SDK%\Include" -L"%VULKAN_SDK%\Lib" -lvulkan-1

#include <vulkan/vulkan.h>
#include "g3d_common.h"
#include "g3d_draw_spv.h"

struct PushC {              // must match the push constants in g3d_draw.comp
    View v;
    int y0, rows, nobj;
};

struct VkBuf {
    VkBuffer buf;
    VkDeviceMemory mem;
    void *map;              // only for host-visible buffers
    VkDeviceSize size;
    int coherent;
};

static VkInstance g_inst = VK_NULL_HANDLE;
static VkPhysicalDevice g_phys = VK_NULL_HANDLE;
static VkDevice g_vdev = VK_NULL_HANDLE;
static VkQueue g_queue = VK_NULL_HANDLE;
static uint32_t g_qfam = 0;
static VkPhysicalDeviceMemoryProperties g_memProps;
static VkPhysicalDeviceProperties g_props;
static VkDescriptorSetLayout g_dsl = VK_NULL_HANDLE;
static VkPipelineLayout g_pl = VK_NULL_HANDLE;
static VkPipeline g_pipe = VK_NULL_HANDLE;
static VkShaderModule g_shader = VK_NULL_HANDLE;
static VkDescriptorPool g_dpool = VK_NULL_HANDLE;
static VkDescriptorSet g_dset = VK_NULL_HANDLE;
static VkCommandPool g_cpool = VK_NULL_HANDLE;
static VkCommandBuffer g_cmd = VK_NULL_HANDLE;
static VkFence g_fence = VK_NULL_HANDLE;
static VkQueryPool g_qpool = VK_NULL_HANDLE;
static int g_hasTime = 0, g_hasBudget = 0;
static VkBuf g_objStage, g_objDev, g_texStage, g_texDev, g_outDev, g_outStage;
static int g_ready = 0;
static float g_kms = 0;
static char g_prefer[128] = "";

static int vchk(VkResult r, const char *where)
{
    if (r != VK_SUCCESS) {
        snprintf(g_err, sizeof g_err, "%s failed (Vulkan error %d)", where, (int)r);
        return 0;
    }
    return 1;
}

// lower-case "contains" for picking a GPU by part of its name
static int name_has(const char *name, const char *part)
{
    char a[256], b[128];
    size_t i;
    for (i = 0; name[i] && i < sizeof a - 1; i++) a[i] = (char)((name[i] >= 'A' && name[i] <= 'Z') ? name[i] + 32 : name[i]);
    a[i] = 0;
    for (i = 0; part[i] && i < sizeof b - 1; i++) b[i] = (char)((part[i] >= 'A' && part[i] <= 'Z') ? part[i] + 32 : part[i]);
    b[i] = 0;
    return strstr(a, b) != NULL;
}

static int find_mem(uint32_t bits, VkMemoryPropertyFlags need, VkMemoryPropertyFlags want)
{
    for (uint32_t i = 0; i < g_memProps.memoryTypeCount; i++) {
        VkMemoryPropertyFlags f = g_memProps.memoryTypes[i].propertyFlags;
        if ((bits & (1u << i)) && (f & (need | want)) == (need | want)) return (int)i;
    }
    for (uint32_t i = 0; i < g_memProps.memoryTypeCount; i++) {
        VkMemoryPropertyFlags f = g_memProps.memoryTypes[i].propertyFlags;
        if ((bits & (1u << i)) && (f & need) == need) return (int)i;
    }
    return -1;
}

static int make_buf(VkBuf &b, VkDeviceSize size, VkBufferUsageFlags usage, int hostVisible, const char *what)
{
    memset(&b, 0, sizeof b);
    b.size = size;
    VkBufferCreateInfo bi = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    bi.size = size;
    bi.usage = usage;
    bi.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (!vchk(vkCreateBuffer(g_vdev, &bi, NULL, &b.buf), what)) return 0;
    VkMemoryRequirements mr;
    vkGetBufferMemoryRequirements(g_vdev, b.buf, &mr);
    int type;
    if (hostVisible) {
        // reading back the frame is much faster from cached memory
        VkMemoryPropertyFlags want = (hostVisible == 2) ? VK_MEMORY_PROPERTY_HOST_CACHED_BIT : VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        type = find_mem(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, want);
    } else {
        type = find_mem(mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, 0);
        if (type < 0) type = find_mem(mr.memoryTypeBits, 0, 0);
    }
    if (type < 0) { snprintf(g_err, sizeof g_err, "%s: no suitable GPU memory", what); return 0; }
    VkMemoryAllocateInfo ai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    ai.allocationSize = mr.size;
    ai.memoryTypeIndex = (uint32_t)type;
    if (!vchk(vkAllocateMemory(g_vdev, &ai, NULL, &b.mem), what)) return 0;
    if (!vchk(vkBindBufferMemory(g_vdev, b.buf, b.mem, 0), what)) return 0;
    if (hostVisible) {
        b.coherent = (g_memProps.memoryTypes[type].propertyFlags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0;
        if (!vchk(vkMapMemory(g_vdev, b.mem, 0, VK_WHOLE_SIZE, 0, &b.map), what)) return 0;
    }
    return 1;
}

static void free_buf(VkBuf &b)
{
    if (!g_vdev) return;
    if (b.map) vkUnmapMemory(g_vdev, b.mem);
    if (b.buf) vkDestroyBuffer(g_vdev, b.buf, NULL);
    if (b.mem) vkFreeMemory(g_vdev, b.mem, NULL);
    memset(&b, 0, sizeof b);
}

static void free_vk(void)
{
    if (g_vdev) vkDeviceWaitIdle(g_vdev);
    free_buf(g_objStage); free_buf(g_objDev);
    free_buf(g_texStage); free_buf(g_texDev);
    free_buf(g_outDev); free_buf(g_outStage);
    if (g_vdev) {
        if (g_qpool) vkDestroyQueryPool(g_vdev, g_qpool, NULL);
        if (g_fence) vkDestroyFence(g_vdev, g_fence, NULL);
        if (g_cpool) vkDestroyCommandPool(g_vdev, g_cpool, NULL);
        if (g_dpool) vkDestroyDescriptorPool(g_vdev, g_dpool, NULL);
        if (g_pipe) vkDestroyPipeline(g_vdev, g_pipe, NULL);
        if (g_pl) vkDestroyPipelineLayout(g_vdev, g_pl, NULL);
        if (g_dsl) vkDestroyDescriptorSetLayout(g_vdev, g_dsl, NULL);
        if (g_shader) vkDestroyShaderModule(g_vdev, g_shader, NULL);
        vkDestroyDevice(g_vdev, NULL);
    }
    if (g_inst) vkDestroyInstance(g_inst, NULL);
    g_inst = VK_NULL_HANDLE; g_phys = VK_NULL_HANDLE; g_vdev = VK_NULL_HANDLE; g_queue = VK_NULL_HANDLE;
    g_dsl = VK_NULL_HANDLE; g_pl = VK_NULL_HANDLE; g_pipe = VK_NULL_HANDLE; g_shader = VK_NULL_HANDLE;
    g_dpool = VK_NULL_HANDLE; g_dset = VK_NULL_HANDLE; g_cpool = VK_NULL_HANDLE; g_cmd = VK_NULL_HANDLE;
    g_fence = VK_NULL_HANDLE; g_qpool = VK_NULL_HANDLE;
    g_ready = 0;
}

// run a one-off command buffer and wait for it
static int run_once(void (*rec)(VkCommandBuffer, void *), void *arg, const char *what)
{
    VkCommandBufferBeginInfo bb = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    bb.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkResetCommandBuffer(g_cmd, 0);
    if (!vchk(vkBeginCommandBuffer(g_cmd, &bb), what)) return 0;
    rec(g_cmd, arg);
    if (!vchk(vkEndCommandBuffer(g_cmd), what)) return 0;
    VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO};
    si.commandBufferCount = 1;
    si.pCommandBuffers = &g_cmd;
    vkResetFences(g_vdev, 1, &g_fence);
    if (!vchk(vkQueueSubmit(g_queue, 1, &si, g_fence), what)) return 0;
    return vchk(vkWaitForFences(g_vdev, 1, &g_fence, VK_TRUE, 10000000000ull), what);
}

struct CopyArg { VkBuffer src, dst; VkDeviceSize off, size; };

static void rec_copy(VkCommandBuffer c, void *p)
{
    CopyArg *a = (CopyArg *)p;
    VkBufferCopy r;
    r.srcOffset = a->off;
    r.dstOffset = a->off;
    r.size = a->size;
    vkCmdCopyBuffer(c, a->src, a->dst, 1, &r);
}

static int upload_tex(VkDeviceSize off, VkDeviceSize size)
{
    if (!g_ready) return 1;
    memcpy((char *)g_texStage.map + off, (char *)g_tex + off, (size_t)size);
    if (!g_texStage.coherent) {
        VkMappedMemoryRange mr = {VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE};
        mr.memory = g_texStage.mem; mr.offset = 0; mr.size = VK_WHOLE_SIZE;
        vkFlushMappedMemoryRanges(g_vdev, 1, &mr);
    }
    CopyArg a = {g_texStage.buf, g_texDev.buf, off, size};
    return run_once(rec_copy, &a, "upload textures");
}

static int pick_device(void)
{
    uint32_t n = 0;
    if (!vchk(vkEnumeratePhysicalDevices(g_inst, &n, NULL), "listing GPUs")) return 0;
    if (n == 0) { snprintf(g_err, sizeof g_err, "no Vulkan GPU found (is the driver installed?)"); return 0; }
    VkPhysicalDevice list[16];
    if (n > 16) n = 16;
    vkEnumeratePhysicalDevices(g_inst, &n, list);

    const char *want = g_prefer[0] ? g_prefer : getenv("G3D_DEVICE");
    int best = -1, bestScore = -1;
    for (uint32_t i = 0; i < n; i++) {
        VkPhysicalDeviceProperties p;
        vkGetPhysicalDeviceProperties(list[i], &p);
        // it needs a queue that can run compute shaders
        uint32_t nq = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(list[i], &nq, NULL);
        VkQueueFamilyProperties qf[32];
        if (nq > 32) nq = 32;
        vkGetPhysicalDeviceQueueFamilyProperties(list[i], &nq, qf);
        int fam = -1;
        for (uint32_t q = 0; q < nq; q++) if (qf[q].queueFlags & VK_QUEUE_COMPUTE_BIT) { fam = (int)q; break; }
        if (fam < 0) continue;
        int score = 0;
        switch (p.deviceType) {
            case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU: score = 30; break;
            case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: score = 20; break;
            case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU: score = 10; break;
            default: score = 1; break;
        }
        if (want && want[0] && name_has(p.deviceName, want)) score += 100;
        if (score > bestScore) {
            bestScore = score; best = (int)i;
            g_phys = list[i]; g_qfam = (uint32_t)fam; g_props = p;
            g_hasTime = (p.limits.timestampComputeAndGraphics || qf[fam].timestampValidBits > 0) && qf[fam].timestampValidBits > 0;
        }
    }
    if (best < 0) { snprintf(g_err, sizeof g_err, "no Vulkan GPU can run compute shaders"); return 0; }
    vkGetPhysicalDeviceMemoryProperties(g_phys, &g_memProps);
    return 1;
}

static int has_dev_ext(const char *name)
{
    uint32_t n = 0;
    vkEnumerateDeviceExtensionProperties(g_phys, NULL, &n, NULL);
    VkExtensionProperties *e = (VkExtensionProperties *)malloc(sizeof(VkExtensionProperties) * (n ? n : 1));
    vkEnumerateDeviceExtensionProperties(g_phys, NULL, &n, e);
    int found = 0;
    for (uint32_t i = 0; i < n; i++) if (strcmp(e[i].extensionName, name) == 0) { found = 1; break; }
    free(e);
    return found;
}

static int setup_vk(int W, int H)
{
    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.pApplicationName = "GPU3D";
    app.pEngineName = "GPU3D";
    app.apiVersion = VK_API_VERSION_1_0;
    VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    ici.pApplicationInfo = &app;
    if (!vchk(vkCreateInstance(&ici, NULL, &g_inst), "starting Vulkan (is a Vulkan driver installed?)")) return 0;
    if (!pick_device()) return 0;

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    qci.queueFamilyIndex = g_qfam;
    qci.queueCount = 1;
    qci.pQueuePriorities = &prio;
    const char *exts[1];
    uint32_t next = 0;
    g_hasBudget = has_dev_ext("VK_EXT_memory_budget");
    if (g_hasBudget) exts[next++] = "VK_EXT_memory_budget";
    VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    dci.enabledExtensionCount = next;
    dci.ppEnabledExtensionNames = exts;
    if (!vchk(vkCreateDevice(g_phys, &dci, NULL, &g_vdev), "opening the GPU")) return 0;
    vkGetDeviceQueue(g_vdev, g_qfam, 0, &g_queue);

    // buffers: shapes and textures are copied up, the frame is copied back
    const VkBufferUsageFlags SSBO = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    const VkBufferUsageFlags SRC = VK_BUFFER_USAGE_TRANSFER_SRC_BIT, DST = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    VkDeviceSize objBytes = G3_MAXOBJ * sizeof(Obj), texBytes = sizeof g_tex, outBytes = (VkDeviceSize)W * H * 4;
    if (!make_buf(g_objStage, objBytes, SRC, 1, "shape buffer")) return 0;
    if (!make_buf(g_objDev, objBytes, SSBO | DST, 0, "shape buffer")) return 0;
    if (!make_buf(g_texStage, texBytes, SRC, 1, "texture buffer")) return 0;
    if (!make_buf(g_texDev, texBytes, SSBO | DST, 0, "texture buffer")) return 0;
    if (!make_buf(g_outDev, outBytes, SSBO | SRC, 0, "frame buffer")) return 0;
    if (!make_buf(g_outStage, outBytes, DST, 2, "frame buffer")) return 0;

    // the compute pipeline
    VkShaderModuleCreateInfo smi = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
    smi.codeSize = sizeof g3d_draw_spv;
    smi.pCode = g3d_draw_spv;
    if (!vchk(vkCreateShaderModule(g_vdev, &smi, NULL, &g_shader), "loading the shader")) return 0;

    VkDescriptorSetLayoutBinding lb[3];
    memset(lb, 0, sizeof lb);
    for (int i = 0; i < 3; i++) {
        lb[i].binding = (uint32_t)i;
        lb[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        lb[i].descriptorCount = 1;
        lb[i].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    }
    VkDescriptorSetLayoutCreateInfo dli = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
    dli.bindingCount = 3;
    dli.pBindings = lb;
    if (!vchk(vkCreateDescriptorSetLayout(g_vdev, &dli, NULL, &g_dsl), "pipeline setup")) return 0;

    VkPushConstantRange pcr;
    pcr.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    pcr.offset = 0;
    pcr.size = sizeof(PushC);
    VkPipelineLayoutCreateInfo pli = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    pli.setLayoutCount = 1;
    pli.pSetLayouts = &g_dsl;
    pli.pushConstantRangeCount = 1;
    pli.pPushConstantRanges = &pcr;
    if (!vchk(vkCreatePipelineLayout(g_vdev, &pli, NULL, &g_pl), "pipeline setup")) return 0;

    VkComputePipelineCreateInfo cpi = {VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
    cpi.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    cpi.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    cpi.stage.module = g_shader;
    cpi.stage.pName = "main";
    cpi.layout = g_pl;
    if (!vchk(vkCreateComputePipelines(g_vdev, VK_NULL_HANDLE, 1, &cpi, NULL, &g_pipe), "building the shader")) return 0;

    VkDescriptorPoolSize ps = {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 3};
    VkDescriptorPoolCreateInfo dpi = {VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
    dpi.maxSets = 1;
    dpi.poolSizeCount = 1;
    dpi.pPoolSizes = &ps;
    if (!vchk(vkCreateDescriptorPool(g_vdev, &dpi, NULL, &g_dpool), "pipeline setup")) return 0;
    VkDescriptorSetAllocateInfo dai = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
    dai.descriptorPool = g_dpool;
    dai.descriptorSetCount = 1;
    dai.pSetLayouts = &g_dsl;
    if (!vchk(vkAllocateDescriptorSets(g_vdev, &dai, &g_dset), "pipeline setup")) return 0;
    VkDescriptorBufferInfo dbi[3] = {
        {g_objDev.buf, 0, VK_WHOLE_SIZE}, {g_texDev.buf, 0, VK_WHOLE_SIZE}, {g_outDev.buf, 0, VK_WHOLE_SIZE}};
    VkWriteDescriptorSet wr[3];
    memset(wr, 0, sizeof wr);
    for (int i = 0; i < 3; i++) {
        wr[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        wr[i].dstSet = g_dset;
        wr[i].dstBinding = (uint32_t)i;
        wr[i].descriptorCount = 1;
        wr[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        wr[i].pBufferInfo = &dbi[i];
    }
    vkUpdateDescriptorSets(g_vdev, 3, wr, 0, NULL);

    VkCommandPoolCreateInfo cpo = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    cpo.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    cpo.queueFamilyIndex = g_qfam;
    if (!vchk(vkCreateCommandPool(g_vdev, &cpo, NULL, &g_cpool), "command setup")) return 0;
    VkCommandBufferAllocateInfo cba = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    cba.commandPool = g_cpool;
    cba.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cba.commandBufferCount = 1;
    if (!vchk(vkAllocateCommandBuffers(g_vdev, &cba, &g_cmd), "command setup")) return 0;
    VkFenceCreateInfo fci = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    if (!vchk(vkCreateFence(g_vdev, &fci, NULL, &g_fence), "command setup")) return 0;
    if (g_hasTime) {
        VkQueryPoolCreateInfo qpi = {VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO};
        qpi.queryType = VK_QUERY_TYPE_TIMESTAMP;
        qpi.queryCount = 2;
        if (vkCreateQueryPool(g_vdev, &qpi, NULL, &g_qpool) != VK_SUCCESS) { g_qpool = VK_NULL_HANDLE; g_hasTime = 0; }
    }
    return 1;
}

// one frame: shapes up, shader, frame back
struct FrameArg { PushC pc; int n; VkDeviceSize outBytes; };

static void rec_frame(VkCommandBuffer c, void *p)
{
    FrameArg *a = (FrameArg *)p;
    if (g_hasTime) vkCmdResetQueryPool(c, g_qpool, 0, 2);

    VkBufferCopy r = {0, 0, (VkDeviceSize)a->n * sizeof(Obj)};
    vkCmdCopyBuffer(c, g_objStage.buf, g_objDev.buf, 1, &r);
    VkMemoryBarrier mb = {VK_STRUCTURE_TYPE_MEMORY_BARRIER};
    mb.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    mb.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    vkCmdPipelineBarrier(c, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &mb, 0, NULL, 0, NULL);

    if (g_hasTime) vkCmdWriteTimestamp(c, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, g_qpool, 0);
    vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_COMPUTE, g_pipe);
    vkCmdBindDescriptorSets(c, VK_PIPELINE_BIND_POINT_COMPUTE, g_pl, 0, 1, &g_dset, 0, NULL);
    vkCmdPushConstants(c, g_pl, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(PushC), &a->pc);
    vkCmdDispatch(c, (uint32_t)(a->pc.v.W + 31) / 32, (uint32_t)(a->pc.rows + 7) / 8, 1);
    if (g_hasTime) vkCmdWriteTimestamp(c, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, g_qpool, 1);

    mb.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
    mb.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    vkCmdPipelineBarrier(c, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
    VkBufferCopy r2 = {0, 0, a->outBytes};
    vkCmdCopyBuffer(c, g_outDev.buf, g_outStage.buf, 1, &r2);
    mb.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    mb.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
    vkCmdPipelineBarrier(c, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
}

extern "C" {

G3_API void g3_shutdown(void)
{
    free_vk();
}

// kept for the CUDA layout; the Vulkan back end draws on one GPU
G3_API void g3_set_weight(int dev, float w)
{
    (void)dev; (void)w;
}

// Pick the GPU by part of its name ("Radeon", "Arc", "GTX"); call before g3_init
G3_API void g3_prefer_device(const char *name)
{
    if (!name) name = "";
    strncpy(g_prefer, name, sizeof g_prefer - 1);
    g_prefer[sizeof g_prefer - 1] = 0;
}

// Start for a W x H image. maxdev is ignored (one GPU). Textures survive a re-init.
G3_API int g3_init(int maxdev, int W, int H)
{
    (void)maxdev;
    free_vk();
    if (W < 16 || H < 16) { snprintf(g_err, sizeof g_err, "bad size"); return 0; }
    if (W != g_view.W || H != g_view.H) view_defaults(W, H);
    if (!setup_vk(W, H)) { free_vk(); return 0; }
    g_ready = 1;
    if (!upload_tex(0, sizeof g_tex)) { free_vk(); return 0; }
    return 1;
}

G3_API int g3_device_count(void) { return g_ready ? 1 : 0; }

G3_API float g3_gpu_ms(int d) { return (g_ready && d == 0) ? g_kms : 0.0f; }

// VRAM in use on the card in MB (0 when the driver can't say)
G3_API float g3_vram_mb(int d)
{
    if (!g_ready || d != 0 || !g_hasBudget) return 0.0f;
    VkPhysicalDeviceMemoryBudgetPropertiesEXT bud = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_BUDGET_PROPERTIES_EXT};
    VkPhysicalDeviceMemoryProperties2 mp = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_PROPERTIES_2};
    mp.pNext = &bud;
    PFN_vkGetPhysicalDeviceMemoryProperties2 fn =
        (PFN_vkGetPhysicalDeviceMemoryProperties2)vkGetInstanceProcAddr(g_inst, "vkGetPhysicalDeviceMemoryProperties2");
    if (!fn) fn = (PFN_vkGetPhysicalDeviceMemoryProperties2)vkGetInstanceProcAddr(g_inst, "vkGetPhysicalDeviceMemoryProperties2KHR");
    if (!fn) return 0.0f;
    fn(g_phys, &mp);
    double used = 0;
    for (uint32_t h = 0; h < mp.memoryProperties.memoryHeapCount; h++)
        if (mp.memoryProperties.memoryHeaps[h].flags & VK_MEMORY_HEAP_DEVICE_LOCAL_BIT) used += (double)bud.heapUsage[h];
    return (float)(used / 1048576.0);
}

// Name of the GPU in use, e.g. "Vulkan: AMD Radeon R5 430 (RADV OLAND)"
G3_API void g3_device_name(int d, char *msg, int msglen)
{
    if (!msg || msglen <= 0) return;
    msg[0] = 0;
    if (!g_ready || d != 0) return;
    snprintf(msg, (size_t)msglen, "Vulkan: %s", g_props.deviceName);
}

// 128x128 32-bit pixels (QB64 _MemImage of a 128x128 image)
G3_API void g3_set_texture(int id, const uint32_t *pixels)
{
    if (!tex_store(id, pixels)) return;
    VkDeviceSize sz = (VkDeviceSize)G3_TEX * G3_TEX * 4;
    upload_tex((VkDeviceSize)id * sz, sz);
}

// Draw the queued shapes into W*H 32-bit pixels (QB64 _MemImage offset).
// mode 0: draw over what is already in the image; mode 1: fill with bg first
G3_API int g3_draw(uint32_t *pixels, int mode, uint32_t bg)
{
    if (!g_ready || !pixels) { snprintf(g_err, sizeof g_err, "not initialised"); return 0; }
    double t0 = now_ms();
    FrameArg a;
    memset(&a, 0, sizeof a);
    a.pc.v = g_view;
    a.pc.v.fill = (mode == 1);
    a.pc.v.bg = bg | 0xFF000000u;
    a.pc.y0 = 0;
    a.pc.rows = g_view.H;
    size_t npix = (size_t)g_view.W * g_view.H;
    a.outBytes = (VkDeviceSize)npix * 4;

    a.n = cull_list(a.pc.v, (Obj *)g_objStage.map);
    a.pc.nobj = a.n;
    if (a.n == 0) {
        if (a.pc.v.fill) {
            for (size_t i = 0; i < npix; i++) pixels[i] = a.pc.v.bg;
        }
        g_gpuMs = 0; g_kms = 0;
        g_hostMs = (float)(now_ms() - t0);
        return 1;
    }
    if (!g_objStage.coherent) {
        VkMappedMemoryRange mr = {VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE};
        mr.memory = g_objStage.mem; mr.offset = 0; mr.size = VK_WHOLE_SIZE;
        vkFlushMappedMemoryRanges(g_vdev, 1, &mr);
    }
    if (!run_once(rec_frame, &a, "drawing")) return 0;
    if (!g_outStage.coherent) {
        VkMappedMemoryRange mr = {VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE};
        mr.memory = g_outStage.mem; mr.offset = 0; mr.size = VK_WHOLE_SIZE;
        vkInvalidateMappedMemoryRanges(g_vdev, 1, &mr);
    }
    if (g_hasTime) {
        uint64_t ts[2] = {0, 0};
        if (vkGetQueryPoolResults(g_vdev, g_qpool, 0, 2, sizeof ts, ts, sizeof(uint64_t),
                                  VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT) == VK_SUCCESS)
            g_kms = (float)((double)(ts[1] - ts[0]) * g_props.limits.timestampPeriod / 1.0e6);
    }
    double t1 = now_ms();
    composite(pixels, (const uint32_t *)g_outStage.map, npix, a.pc.v.fill);
    double t2 = now_ms();
    g_gpuMs = (float)(t1 - t0);
    g_hostMs = (float)(t2 - t1);
    if (!g_hasTime) g_kms = g_gpuMs;
    return 1;
}

} // extern "C"

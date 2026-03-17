/*
 * vk_pool_fix_diag.c - Diagnostic version of vk_pool_fix
 *
 * Keeps the original pool fix AND adds logging for:
 * - Swapchain creation (present mode, image count, extent)
 * - Frame present timing (interval, duration, jitter)
 * - Image acquire timing (stalls, errors)
 * - vkGetDeviceProcAddr interception (ensures hooks work even if
 *   GTK4 resolves function pointers directly)
 *
 * Build: gcc -shared -fPIC -o vk_pool_fix_diag.so vk_pool_fix_diag.c -ldl
 * Use:   LD_PRELOAD=/path/to/vk_pool_fix_diag.so ptyxis
 * Watch: journalctl --user -f | grep vk_diag
 *   or:  LD_PRELOAD=... ptyxis 2>&1 | grep vk_diag
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <vulkan/vulkan.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <stdint.h>

#define POOL_MULTIPLIER 200

/* ── helpers ─────────────────────────────────────────────────────── */

#define LOG(fmt, ...) fprintf(stderr, "[vk_diag] " fmt "\n", ##__VA_ARGS__)

static inline double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}

static const char *present_mode_str(VkPresentModeKHR m)
{
    switch (m) {
    case VK_PRESENT_MODE_IMMEDIATE_KHR:    return "IMMEDIATE";
    case VK_PRESENT_MODE_MAILBOX_KHR:      return "MAILBOX";
    case VK_PRESENT_MODE_FIFO_KHR:         return "FIFO";
    case VK_PRESENT_MODE_FIFO_RELAXED_KHR: return "FIFO_RELAXED";
    default:                               return "UNKNOWN";
    }
}

static const char *vkresult_str(VkResult r)
{
    switch (r) {
    case VK_SUCCESS:                  return "SUCCESS";
    case VK_TIMEOUT:                  return "TIMEOUT";
    case VK_NOT_READY:                return "NOT_READY";
    case VK_SUBOPTIMAL_KHR:           return "SUBOPTIMAL";
    case VK_ERROR_OUT_OF_DATE_KHR:    return "OUT_OF_DATE";
    case VK_ERROR_OUT_OF_POOL_MEMORY: return "OUT_OF_POOL_MEMORY";
    case VK_ERROR_DEVICE_LOST:        return "DEVICE_LOST";
    case VK_ERROR_SURFACE_LOST_KHR:   return "SURFACE_LOST";
    default:                          return "OTHER";
    }
}

/* ── 1. descriptor pool fix (original) ───────────────────────────── */

typedef VkResult (*PFN_vkCreateDescriptorPool)(
    VkDevice, const VkDescriptorPoolCreateInfo *,
    const VkAllocationCallbacks *, VkDescriptorPool *);

VkResult vkCreateDescriptorPool(
    VkDevice device,
    const VkDescriptorPoolCreateInfo *pCreateInfo,
    const VkAllocationCallbacks *pAllocator,
    VkDescriptorPool *pDescriptorPool)
{
    static PFN_vkCreateDescriptorPool real_fn = NULL;
    if (!real_fn) {
        real_fn = (PFN_vkCreateDescriptorPool)dlsym(RTLD_NEXT,
                  "vkCreateDescriptorPool");
        if (!real_fn) return VK_ERROR_INITIALIZATION_FAILED;
    }

    VkDescriptorPoolCreateInfo mod = *pCreateInfo;
    mod.maxSets = pCreateInfo->maxSets * POOL_MULTIPLIER;

    VkDescriptorPoolSize sizes[32];
    uint32_t count = pCreateInfo->poolSizeCount;
    if (count > 32) {
        LOG("WARN CreateDescriptorPool: poolSizeCount=%u > 32, clamped", count);
        count = 32;
    }
    for (uint32_t i = 0; i < count; i++) {
        sizes[i] = pCreateInfo->pPoolSizes[i];
        sizes[i].descriptorCount *= POOL_MULTIPLIER;
    }
    mod.poolSizeCount = count;
    mod.pPoolSizes = sizes;

    VkResult r = real_fn(device, &mod, pAllocator, pDescriptorPool);
    LOG("CreateDescriptorPool: maxSets %u->%u, types=%u, result=%s",
        pCreateInfo->maxSets, mod.maxSets, count, vkresult_str(r));
    return r;
}

/* ── 2. swapchain creation ───────────────────────────────────────── */

typedef VkResult (*PFN_vkCreateSwapchainKHR)(
    VkDevice, const VkSwapchainCreateInfoKHR *,
    const VkAllocationCallbacks *, VkSwapchainKHR *);

VkResult vkCreateSwapchainKHR(
    VkDevice device,
    const VkSwapchainCreateInfoKHR *pCreateInfo,
    const VkAllocationCallbacks *pAllocator,
    VkSwapchainKHR *pSwapchain)
{
    static PFN_vkCreateSwapchainKHR real_fn = NULL;
    if (!real_fn) {
        real_fn = (PFN_vkCreateSwapchainKHR)dlsym(RTLD_NEXT,
                  "vkCreateSwapchainKHR");
        if (!real_fn) return VK_ERROR_INITIALIZATION_FAILED;
    }

    LOG("CreateSwapchain: presentMode=%s(%d), minImages=%u, "
        "extent=%ux%u, imageUsage=0x%x, compositeAlpha=0x%x",
        present_mode_str(pCreateInfo->presentMode),
        pCreateInfo->presentMode,
        pCreateInfo->minImageCount,
        pCreateInfo->imageExtent.width,
        pCreateInfo->imageExtent.height,
        pCreateInfo->imageUsage,
        pCreateInfo->compositeAlpha);

    VkResult r = real_fn(device, pCreateInfo, pAllocator, pSwapchain);
    LOG("CreateSwapchain result: %s(%d)", vkresult_str(r), r);
    return r;
}

/* ── 3. queue present (frame timing) ─────────────────────────────── */

typedef VkResult (*PFN_vkQueuePresentKHR)(
    VkQueue, const VkPresentInfoKHR *);

VkResult vkQueuePresentKHR(
    VkQueue queue,
    const VkPresentInfoKHR *pPresentInfo)
{
    static PFN_vkQueuePresentKHR real_fn = NULL;
    static double last_ms      = 0;
    static uint64_t count      = 0;
    static uint64_t err_count  = 0;
    static double min_delta    = 1e9;
    static double max_delta    = 0;
    static double sum_delta    = 0;

    if (!real_fn) {
        real_fn = (PFN_vkQueuePresentKHR)dlsym(RTLD_NEXT,
                  "vkQueuePresentKHR");
        if (!real_fn) return VK_ERROR_INITIALIZATION_FAILED;
    }

    double t0 = now_ms();
    VkResult r = real_fn(queue, pPresentInfo);
    double t1 = now_ms();

    double delta   = (last_ms > 0) ? (t0 - last_ms) : 0;
    double dur     = t1 - t0;
    count++;

    if (r != VK_SUCCESS && r != VK_SUBOPTIMAL_KHR)
        err_count++;

    /* track jitter stats (skip first frame) */
    if (count > 1) {
        if (delta < min_delta) min_delta = delta;
        if (delta > max_delta) max_delta = delta;
        sum_delta += delta;
    }

    /* log EVERY frame for full timing analysis */
    int jitter = (count > 2 && (delta < 4.0 || delta > 50.0));
    LOG("P #%lu: d=%.1f dur=%.2f r=%s%s",
        (unsigned long)count, delta, dur,
        vkresult_str(r),
        jitter ? " [J]" : "");

    /* summary every 300 frames */
    if (count % 300 == 0 && count > 1) {
        double avg = sum_delta / (count - 1);
        LOG("Present stats: %lu frames, %lu errors, "
            "delta min=%.1f avg=%.1f max=%.1fms, jitter=%.1fms",
            (unsigned long)count, (unsigned long)err_count,
            min_delta, avg, max_delta, max_delta - min_delta);
    }

    last_ms = t0;
    return r;
}

/* ── 4. acquire next image ───────────────────────────────────────── */

typedef VkResult (*PFN_vkAcquireNextImageKHR)(
    VkDevice, VkSwapchainKHR, uint64_t,
    VkSemaphore, VkFence, uint32_t *);

VkResult vkAcquireNextImageKHR(
    VkDevice device,
    VkSwapchainKHR swapchain,
    uint64_t timeout,
    VkSemaphore semaphore,
    VkFence fence,
    uint32_t *pImageIndex)
{
    static PFN_vkAcquireNextImageKHR real_fn = NULL;
    static uint64_t count      = 0;
    static uint64_t slow_count = 0;

    if (!real_fn) {
        real_fn = (PFN_vkAcquireNextImageKHR)dlsym(RTLD_NEXT,
                  "vkAcquireNextImageKHR");
        if (!real_fn) return VK_ERROR_INITIALIZATION_FAILED;
    }

    double t0 = now_ms();
    VkResult r = real_fn(device, swapchain, timeout,
                         semaphore, fence, pImageIndex);
    double dur = now_ms() - t0;
    count++;

    if (dur > 2.0) slow_count++;

    uint32_t idx = (r == VK_SUCCESS || r == VK_SUBOPTIMAL_KHR)
                   ? *pImageIndex : 0;

    /* log first 10, every 60th, slow (>5ms), or errors */
    if (count <= 10 || count % 60 == 0 || dur > 5.0 ||
        (r != VK_SUCCESS && r != VK_SUBOPTIMAL_KHR)) {
        LOG("Acquire #%lu: dur=%.2fms idx=%u result=%s%s",
            (unsigned long)count, dur, idx,
            vkresult_str(r),
            dur > 5.0 ? " [SLOW]" : "");
    }

    if (count % 300 == 0) {
        LOG("Acquire stats: %lu total, %lu slow (>2ms)",
            (unsigned long)count, (unsigned long)slow_count);
    }

    return r;
}

/* ── 5. intercept vkGetDeviceProcAddr ────────────────────────────── *
 * GTK4/GSK may resolve function pointers via vkGetDeviceProcAddr    *
 * instead of using the loader trampolines. We must return our       *
 * wrappers so the hooks actually fire.                               */

typedef PFN_vkVoidFunction (*PFN_vkGetDeviceProcAddr)(
    VkDevice, const char *);

PFN_vkVoidFunction vkGetDeviceProcAddr(
    VkDevice device,
    const char *pName)
{
    static PFN_vkGetDeviceProcAddr real_fn = NULL;
    if (!real_fn) {
        real_fn = (PFN_vkGetDeviceProcAddr)dlsym(RTLD_NEXT,
                  "vkGetDeviceProcAddr");
        if (!real_fn) return NULL;
    }

    /* return our wrappers for hooked functions */
    if (strcmp(pName, "vkCreateDescriptorPool") == 0)
        return (PFN_vkVoidFunction)vkCreateDescriptorPool;
    if (strcmp(pName, "vkCreateSwapchainKHR") == 0)
        return (PFN_vkVoidFunction)vkCreateSwapchainKHR;
    if (strcmp(pName, "vkQueuePresentKHR") == 0)
        return (PFN_vkVoidFunction)vkQueuePresentKHR;
    if (strcmp(pName, "vkAcquireNextImageKHR") == 0)
        return (PFN_vkVoidFunction)vkAcquireNextImageKHR;

    return real_fn(device, pName);
}

/* ── 6. intercept vkGetInstanceProcAddr ──────────────────────────── *
 * Some paths resolve through instance rather than device.            */

typedef PFN_vkVoidFunction (*PFN_vkGetInstanceProcAddr)(
    VkInstance, const char *);

PFN_vkVoidFunction vkGetInstanceProcAddr(
    VkInstance instance,
    const char *pName)
{
    static PFN_vkGetInstanceProcAddr real_fn = NULL;
    if (!real_fn) {
        real_fn = (PFN_vkGetInstanceProcAddr)dlsym(RTLD_NEXT,
                  "vkGetInstanceProcAddr");
        if (!real_fn) return NULL;
    }

    if (strcmp(pName, "vkCreateDescriptorPool") == 0)
        return (PFN_vkVoidFunction)vkCreateDescriptorPool;
    if (strcmp(pName, "vkCreateSwapchainKHR") == 0)
        return (PFN_vkVoidFunction)vkCreateSwapchainKHR;
    if (strcmp(pName, "vkQueuePresentKHR") == 0)
        return (PFN_vkVoidFunction)vkQueuePresentKHR;
    if (strcmp(pName, "vkAcquireNextImageKHR") == 0)
        return (PFN_vkVoidFunction)vkAcquireNextImageKHR;
    if (strcmp(pName, "vkGetDeviceProcAddr") == 0)
        return (PFN_vkVoidFunction)vkGetDeviceProcAddr;

    return real_fn(instance, pName);
}

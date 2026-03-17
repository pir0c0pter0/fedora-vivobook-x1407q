/*
 * vk_pool_fix.c - LD_PRELOAD fix for GTK4/turnip descriptor pool exhaustion
 *
 * Problem: GTK4's Vulkan renderer (GSK) creates descriptor pools with
 * maxSets=100 and FREE_DESCRIPTOR_SET_BIT. The freedreno turnip driver
 * fragments these small pools under rapid alloc/free cycles, causing
 * VK_ERROR_OUT_OF_POOL_MEMORY and visible flicker.
 *
 * Fix: Intercepts vkCreateDescriptorPool and increases maxSets and
 * descriptorCount by 200x (100 -> 20000), drastically reducing fragmentation.
 * Also intercepts vkGetDeviceProcAddr/vkGetInstanceProcAddr to ensure the
 * hook works even when GTK4 resolves function pointers directly.
 *
 * Build: gcc -shared -fPIC -o vk_pool_fix.so vk_pool_fix.c -ldl
 * Use:   LD_PRELOAD=/path/to/vk_pool_fix.so ptyxis
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <vulkan/vulkan.h>
#include <string.h>
#include <stdio.h>

#define POOL_MULTIPLIER 200
#define MAX_POOL_SIZES  32

typedef VkResult (*PFN_vkCreateDescriptorPool)(
    VkDevice device,
    const VkDescriptorPoolCreateInfo *pCreateInfo,
    const VkAllocationCallbacks *pAllocator,
    VkDescriptorPool *pDescriptorPool);

VkResult vkCreateDescriptorPool(
    VkDevice device,
    const VkDescriptorPoolCreateInfo *pCreateInfo,
    const VkAllocationCallbacks *pAllocator,
    VkDescriptorPool *pDescriptorPool)
{
    static PFN_vkCreateDescriptorPool real_fn = NULL;
    if (!real_fn) {
        real_fn = (PFN_vkCreateDescriptorPool)dlsym(RTLD_NEXT, "vkCreateDescriptorPool");
        if (!real_fn)
            return VK_ERROR_INITIALIZATION_FAILED;
    }

    /* Copy and enlarge the pool create info */
    VkDescriptorPoolCreateInfo modified = *pCreateInfo;
    modified.maxSets = pCreateInfo->maxSets * POOL_MULTIPLIER;

    /* Enlarge each pool size entry */
    VkDescriptorPoolSize sizes[MAX_POOL_SIZES];
    uint32_t count = pCreateInfo->poolSizeCount;
    if (count > MAX_POOL_SIZES) {
        fprintf(stderr, "[vk_pool_fix] WARN: poolSizeCount=%u > %d, clamped\n",
                count, MAX_POOL_SIZES);
        count = MAX_POOL_SIZES;
    }

    for (uint32_t i = 0; i < count; i++) {
        sizes[i] = pCreateInfo->pPoolSizes[i];
        sizes[i].descriptorCount *= POOL_MULTIPLIER;
    }
    modified.poolSizeCount = count;
    modified.pPoolSizes = sizes;

    return real_fn(device, &modified, pAllocator, pDescriptorPool);
}

/* ── vkGetDeviceProcAddr interception ────────────────────────────── *
 * GTK4/GSK may resolve function pointers via vkGetDeviceProcAddr    *
 * bypassing LD_PRELOAD trampolines. Return our wrapper so the pool  *
 * fix is always active regardless of how the app resolves symbols.  */

typedef PFN_vkVoidFunction (*PFN_vkGetDeviceProcAddr)(
    VkDevice, const char *);

PFN_vkVoidFunction vkGetDeviceProcAddr(
    VkDevice device,
    const char *pName)
{
    static PFN_vkGetDeviceProcAddr real_fn = NULL;
    if (!real_fn) {
        real_fn = (PFN_vkGetDeviceProcAddr)dlsym(RTLD_NEXT, "vkGetDeviceProcAddr");
        if (!real_fn)
            return NULL;
    }

    if (strcmp(pName, "vkCreateDescriptorPool") == 0)
        return (PFN_vkVoidFunction)vkCreateDescriptorPool;

    return real_fn(device, pName);
}

/* ── vkGetInstanceProcAddr interception ──────────────────────────── *
 * Some paths resolve device functions through the instance. Also     *
 * return our vkGetDeviceProcAddr wrapper to chain correctly.         */

typedef PFN_vkVoidFunction (*PFN_vkGetInstanceProcAddr)(
    VkInstance, const char *);

PFN_vkVoidFunction vkGetInstanceProcAddr(
    VkInstance instance,
    const char *pName)
{
    static PFN_vkGetInstanceProcAddr real_fn = NULL;
    if (!real_fn) {
        real_fn = (PFN_vkGetInstanceProcAddr)dlsym(RTLD_NEXT, "vkGetInstanceProcAddr");
        if (!real_fn)
            return NULL;
    }

    if (strcmp(pName, "vkCreateDescriptorPool") == 0)
        return (PFN_vkVoidFunction)vkCreateDescriptorPool;
    if (strcmp(pName, "vkGetDeviceProcAddr") == 0)
        return (PFN_vkVoidFunction)vkGetDeviceProcAddr;

    return real_fn(instance, pName);
}

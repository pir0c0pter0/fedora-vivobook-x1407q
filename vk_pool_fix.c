/*
 * vk_pool_fix.c - LD_PRELOAD fix for GTK4/turnip descriptor pool exhaustion
 *
 * Problem: GTK4's Vulkan renderer (GSK) creates descriptor pools with
 * maxSets=100 and FREE_DESCRIPTOR_SET_BIT. The freedreno turnip driver
 * fragments these small pools under rapid alloc/free cycles, causing
 * VK_ERROR_OUT_OF_POOL_MEMORY and visible flicker.
 *
 * Fix: Intercepts vkCreateDescriptorPool and increases maxSets and
 * descriptorCount by 50x (100 -> 5000), drastically reducing fragmentation.
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
    VkDescriptorPoolSize sizes[16];
    uint32_t count = pCreateInfo->poolSizeCount;
    if (count > 16) count = 16;

    for (uint32_t i = 0; i < count; i++) {
        sizes[i] = pCreateInfo->pPoolSizes[i];
        sizes[i].descriptorCount *= POOL_MULTIPLIER;
    }
    modified.poolSizeCount = count;
    modified.pPoolSizes = sizes;

    return real_fn(device, &modified, pAllocator, pDescriptorPool);
}

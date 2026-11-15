// Vulkan Memory Allocator (VMA) para o backend Vulkan (ADR 0024). Só existe no Android: no host (macOS,
// Linux) o módulo fica vazio e compila sem os cabeçalhos Vulkan.
#ifndef CAJU_CVMA_H
#define CAJU_CVMA_H

#if defined(__ANDROID__)
#include <vulkan/vulkan.h>
#include "vk_mem_alloc.h"
#endif

#endif

// Implementação do VMA (cabeçalho único). Compila só no Android; no host a unidade fica vazia.
#if defined(__ANDROID__)
// Funções ligadas estaticamente a libvulkan.so (piso Vulkan 1.1, ADR 0024); sem carga dinâmica.
#define VMA_STATIC_VULKAN_FUNCTIONS 1
#define VMA_DYNAMIC_VULKAN_FUNCTIONS 0
#define VMA_VULKAN_VERSION 1001000
// Sem iostream/printf: o VMA não imprime estatísticas por conta própria.
#define VMA_STATS_STRING_ENABLED 0
#define VMA_IMPLEMENTATION
#pragma clang diagnostic ignored "-Wnullability-completeness"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include <vulkan/vulkan.h>
#include "vk_mem_alloc.h"
#endif

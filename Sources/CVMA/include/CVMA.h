// Alvo da implementação do VMA (`vma_impl.cpp`; ADR 0024). Só existe no Android.
//
// As declarações do VMA são importadas pelo módulo `CVulkan` (`Sources/CVulkan/shim.h` inclui
// `include/vk_mem_alloc.h`): dois módulos Clang incluindo `vulkan.h` separadamente fazem o Swift perder
// os símbolos Vulkan nos arquivos que importam só um deles. Código Swift usa `import CVulkan`.
#ifndef CAJU_CVMA_H
#define CAJU_CVMA_H
#endif

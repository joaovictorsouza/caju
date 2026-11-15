# CVMA

Alvo C++ com o [Vulkan Memory Allocator](https://github.com/GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator) **3.5.0** vendorizado (cabeçalho único, sem modificações), política do ADR 0005. Decisões em [ADR 0024](../../docs/adr/README.md) (VMA e sincronização do backend Vulkan; trilha V-1).

- Só o `CajuRHIVulkan` consome este alvo, e só no Android. No host o módulo compila vazio (`#if defined(__ANDROID__)`).
- `vma_impl.cpp` traz a implementação (`VMA_IMPLEMENTATION`), com funções Vulkan ligadas estaticamente (`VMA_STATIC_VULKAN_FUNCTIONS`) e piso Vulkan 1.1.
- O Swift importa só a parte de declarações (API C do VMA); o `module.modulemap` próprio evita o `requires cplusplus` que o SwiftPM geraria.
- Versão, origem e hash em `VERSION`. Para atualizar: PR dedicado que troca `include/vk_mem_alloc.h` e `VERSION`.
- Fora do `swift-format` e do `check-forbidden.sh` (código de terceiros).

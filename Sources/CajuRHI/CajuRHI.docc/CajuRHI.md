# ``CajuRHI``

Interface de GPU para Metal e Vulkan: handles geracionais, render pass com transientes, *frame graph* e backend de teste.

## Visão geral

O dispositivo (``CajuRenderDevice``) cria recursos e entrega a fila (``CajuQueue``); um ``CajuCommandBuffer`` grava passes de render, compute e cópia em *closures* que entregam encoders `~Copyable`. O ``CajuFrameGraphBuilder`` declara passes e recursos de um quadro e ``CajuCompiledFrameGraph`` decide quais texturas são `memoryless` e quais compartilham memória.

## Tópicos

### Recursos
- ``CajuHandle``
- ``CajuTextureDescriptor``
- ``CajuBufferDescriptor``
- ``CajuPixelFormat``

### Comandos
- ``CajuRenderDevice``
- ``CajuCommandBuffer``
- ``CajuRenderEncoder``

### Frame graph
- ``CajuFrameGraphBuilder``
- ``CajuCompiledFrameGraph``
- ``CajuFrameGraphExecutor``

### Testes
- ``CajuNullDevice``

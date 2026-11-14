# ADR 0001: RHI próprio (Metal + Vulkan) e shaders em Slang

**Status:** Aceito (decisão do dono; sem spike de wgpu por agora).

## Contexto
O rascunho propunha WebGPU nativo (Dawn/wgpu-native) como backend padrão. Mobile é o alvo principal; footprint de memória (NFR-004), tamanho de binário (NFR-007) e latência pesam mais que alcance de plataformas.

## Decisão
- **RHI próprio**, com backends **Metal** (Apple) e **Vulkan** (Android; depois Linux/Windows), desenhados **juntos** desde o início.
- A semântica do RHI parte de **render pass/subpass + `TransientAttachment` (memoryless)** e *frame graph*, e não de "WebGPU-like".
- **Shaders em Slang**, compilados offline para MSL e SPIR-V, com reflexão que gera structs Swift. Sem compilador de shader em runtime.
- **Sem spike de `wgpu-native` por agora.** O spike no Android passa a validar o **Vulkan próprio + VMA no Galaxy S22**: footprint com MSAA 4x, recriação de superfície (50 ciclos de background/rotação), tamanho do binário, p95 de CPU com ~1000 draws.

## Alternativas
- `wgpu-native`/Dawn: um backend para todas as plataformas (inclui Web), menos código nosso, mas toolchain Rust no build, tamanho estimado 2–3 MB por ABI (?) e possível falta de transient attachments.
- Fork do wgpu: descartado (manutenção de Rust).

## Consequências
- Mais código de GPU para manter (estimativa 7,5–11 mil linhas (?); Vulkan Android 2–3 meses-engenheiro no escopo MVP (?)).
- Backend WebGPU futuro (Web) entra atrás da mesma interface; extensões de render pass/transient degradam nele (perde footprint, não funcionalidade).
- Cada backend passa na mesma suíte de conformidade (*goldens*).

## Quando reabrir
Se o Vulkan próprio estourar o orçamento de tempo, ou se Web/Windows virarem meta de curto prazo: reabrir comparação com wgpu.

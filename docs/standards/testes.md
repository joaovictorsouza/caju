# Estratégia de testes

**Framework:** Swift Testing (e XCTest só onde necessário, p. ex. medição). Tudo que for puro roda em **Linux e macOS** no CI.

| Camada | O quê | Onde roda |
|---|---|---|
| Unitários puros | Math (testes de propriedade, ≥ 10 000 casos, tolerância 1e-5), ECS, agendador, estados, mensagens, layout, medida de texto, parsers, BVH | Linux + macOS |
| Propriedade/fuzz | Parsers (glTF, KTX2, meshopt, fontes, JSON): nenhuma entrada causa crash, leitura fora do limite ou alocação acima do limite | Linux + macOS (CI noturno com mais iterações) |
| Integração headless | `TestApp` (relógio manual, sem janela/GPU) + `NullRenderer` + servidores falsos | Linux + macOS |
| Conformidade de GPU | *Goldens* por backend (Metal, Vulkan), mesma cena, tolerância por pixel/SSIM; modos `uniform`/`storage` equivalentes | macOS/iOS; Android em aparelho |
| Benchmarks | ECS (NFR-008), layout (NFR-009), draw calls, quadro p50/p95 | CI (CPU) + aparelhos de referência (JSON versionado) |
| Concorrência | Thread Sanitizer, verificação estrita | Linux + macOS |
| Aparelho | Ciclos de background/resume, rotação, recriação de superfície, soak | Galaxy S22, iPhone 16 Pro |

## Regras
- **Teste junto com o código**; bug corrigido ganha teste de regressão.
- **Determinismo:** `TimeUpdateStrategy.manual`, `Random` semeável (PCG); sem relógio de parede nem aleatoriedade não semeada em testes.
- **Goldens:** atualização só por flag explícita e revisada no PR; um conjunto por backend.
- **Benchmarks:** regressão > 10 % bloqueia merge; resultado guardado como JSON.
- **Cobertura:** não há meta numérica global; o critério é *todo requisito `DEVE` do módulo tem teste* (rastreio por ID do catálogo).
- Teste instável não é desligado: é corrigido ou removido com justificativa no PR.

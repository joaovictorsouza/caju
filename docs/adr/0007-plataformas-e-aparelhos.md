# ADR 0007: Plataformas, SO mínimo e aparelhos de referência

**Status:** Aceito.

## Decisão
- **Alvos v1:** iOS ≥ 17, Android API ≥ 29 (`arm64-v8a`), macOS ≥ 14 (desenvolvimento/testes). Linux compila e testa todos os módulos sem GPU.
- **Aparelhos de referência:** **Android: Galaxy S22+ com Snapdragon 8 Gen 1/Adreno 730** (variante confirmada pelo dono em 2026-11-14); **iOS: iPhone 16 Pro** (topo).
- Sugestão (não bloqueante): adicionar um aparelho de piso (iPhone de 2–3 gerações atrás ou Android de entrada) para orçamentos de memória e térmico.
- Web, Windows, Linux com GPU e visionOS/tvOS: fora da v1; a interface do RHI mantém a porta aberta (ADR 0001).

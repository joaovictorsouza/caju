# Performance: orçamentos e regras

Metas medidas nos aparelhos de referência (Galaxy S22, iPhone 16 Pro; ADR 0007). Estimativas `(?)` até medir.

- **ECS:** ≥ 100 000 entidades com 3 componentes por consulta em < 2 ms no aparelho alto; `spawn` ≥ 1 milhão/s.
- **Layout de UI:** 1 000 nós em < 1 ms de CPU com árvore estável; UI de tela cheia ≤ 1,5 ms CPU/quadro. Medido (P-4, Linux x86-64 de nuvem, release, relayout completo de ~1 000 nós): ≈ 45 µs; hit-test ≈ 0,1–0,3 µs. Ainda sem medida nos aparelhos de referência `(?)`.
- **Draw calls:** ≤ 300 por quadro; UI ≤ 40.
- **Memória:** GPU ≤ 300 MB; residente ≤ 600 MB no cenário de referência.
- **Sem travadas:** nenhum quadro > 50 ms por compilação de pipeline, upload de textura ou carga de asset.
- **Quadro sem mudança** de UI custa só uma checagem de sujeira.
- **Display list da UI** (contrato U-1, [ADR 0026](../adr/0026-ui-display-list-e-dsl.md)): reconstrução reaproveita armazenamento (0 alocação em quadro estável); `revision`/`propsRevision` iguais ⇒ zero trabalho de CPU no batcher; mudança só de desenho altera apenas a tabela de camadas. `body` < 100 ns `(?)`, ≤ 40 draw calls na tela de loja `(?)`; sem *parameter packs* no caminho quente (ADR 0014).

## Regras
1. Nenhuma alocação por quadro no caminho quente (verificado por inspeção de SIL/instrumentação em testes dos módulos quentes).
2. Todo módulo com meta tem *benchmark* no CI desde a primeira versão.
3. Otimização só com *benchmark* antes e depois no PR.
4. Harness: `swift run -c release caju-bench` (JSON). O gate de 10 % só liga com linha de base de aparelho; números de runner de CI não são de referência.
5. Tamanho de binário e tempo de compilação incremental medidos no CI; regressões aparecem no PR.

## TB-2: frame graph e ciclos de superfície (medidos 2026-11-14, Mac Apple Silicon, **não são números de aparelho**)
Fonte: `Tests/CajuModulesTests/CajuFrameGraphBenchmarkTests.swift` e `CajuMetalTests.swift` (CPU, backend null; 1000 iterações).

| Cenário | Debug (`swift test`) mediana / p95 | Release (`swift test -c release`) mediana / p95 |
|---|---|---|
| `compile()` 5 passes | 25,8 / 26,2 µs | 3,5 / 3,6 µs |
| `execute()+submit` 5 passes | 13,9 / 14,0 µs | 2,5 / 2,7 µs |
| `compile()` 50 passes | 228,5 / 237,9 µs | 23,7 / 23,9 µs |
| `execute()+submit` 50 passes | 124,8 / 128,1 µs | 21,6 / 21,8 µs |

- 50 ciclos de background/resume (recriação de superfície com tamanho alternado, Metal, `CAMetalLayer` sem janela): ΔRSS = 0,14 MB (gate ADR 0006: ≤ 1 MB), recursos vivos constantes.
- O benchmark roda como teste porque `caju-bench` depende de `Package.swift` (trancado); migrar para o executável é PR dedicado. Números de aparelho (iPhone 16 Pro, S22+) e p95 de quadro: `(?)`. Alocação por quadro do executor no estado estável não foi medida `(?)`.


## S-0: linhas de base em aparelho (medidas 2026-11-15)
Detalhes e comandos em `docs/evidencias/s0-android/` (Galaxy S22+, SM-S906E, Android 16) e `docs/evidencias/s0-ios/` (iPhone 16 Pro). Mediana de 5 execuções; razão S22+/Mac M1 em parênteses.

- **Layout de UI, 1 000 nós (relayout completo):** S22+ 49,9 µs (1,60x o M1); ≪ meta de 1 ms.
- **BVH 10 k, SAH:** build 1,40 ms; `raycastFirst` 1 000 raios 1,43 ms; triângulos 20 k: build 0,60 ms, `raycastFirst` 0,35 ms (S22+).
- **ECS no S22+:** `query.arity3` 100 k = 3,1 ns/entidade; `spawn` 3 componentes = 419 ns (≈ 2,4 M/s; meta ≥ 1 M/s).
- **Compilação incremental (≤ 5 s):** 1,4 a 1,8 s no Mac e no Android (medianas, `CajuMath` e `CajuUILayout`).
- **`.apk`:** debug 30,7 MB; release com stdlib estática e `strip` 8,5 MB. Teto proposto: ver ADR 0020.
- **iPhone 16 Pro (Debug, 60 Hz):** 50 ciclos ΔRSS 0,016 MB; soak 5 min sem quadro perdido (p95 = 16,67 ms = vsync); background/resume reais estáveis.

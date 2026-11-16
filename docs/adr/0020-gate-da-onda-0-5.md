# ADR 0020: Resultado do gate de saída da Onda 0.5 (S-0)

**Status:** Aceito, gate **parcialmente fechado** (ver "Pendente"). Medido em 2026-11-15.

## Contexto
O ADR 0006 definiu o gate de saída antes da Onda 1, com números "a calibrar". A S-0 mediu o que cabe sem o backend Vulkan completo (V-1) e sem o render integrado (R-1). Evidências: `docs/evidencias/s0-android/` (Galaxy S22+) e `docs/evidencias/s0-ios/` (iPhone 16 Pro).

## Resultado por critério
| Critério (ADR 0006) | Resultado | Situação |
|---|---|---|
| 50 ciclos de background/resume e recriação de superfície, ΔRSS ≤ 1 MB | **iPhone 16 Pro:** ΔRSS 0,016 MB; recursos vivos estáveis; 5 voltas reais de background sem erro. Mac: 0,14 MB (TB-2). **Android:** não medido | iOS/macOS **fechado**; Android com V-1 |
| Soak de 5 min por aparelho, p95 < 16 ms | **iPhone 16 Pro:** 18 000 quadros, intervalo p95 = 16,67 ms (= vsync de 60 Hz), nenhum quadro perdido, térmico nominal. **S22+:** sem cena de GPU além do triângulo | iOS **fechado com ressalva** (critério reescrito abaixo); Android com V-1 |
| TSan limpo em Linux/macOS; SIL do `Query` sem alocação | TSan limpo no Mac (`swift test --sanitize=thread`) e no CI Linux. SIL do `Query`: **não verificado na S-0** | TSan **fechado**; SIL fica para o gate da Onda 1 (A-1) |
| `Observation` em Android real | OK no S22+ (`withObservationTracking` dispara uma vez; `docs/evidencias/s0-android/observation/`) | **Fechado** |
| Compilação incremental de módulo ≤ 5 s | Medianas 1,43 a 1,83 s (Mac e Android, `CajuMath`/`CajuUILayout`) | **Fechado** |
| Tamanho do `.apk` (a medir, ADR 0005) | Debug 30,7 MB; release com stdlib estática e `strip` 8,5 MB (sem assinatura) | **Medido**; teto abaixo |
| Toque no iPhone 16 Pro (TB-2) | 8 acertos seguidos; bug do espaço de coordenadas achado e corrigido | **Fechado** |
| Aliasing por heap no Metal (TB-2) | Não implementado (ADR 0015 já o listava como pendente); nada a medir | **Vai para a R-1** |

## Decisões
1. **Critério de soak reescrito.** "p95 < 16 ms" é impossível de medir em tela de 60 Hz (o intervalo mínimo é 16,67 ms). O critério passa a ser: **nenhum quadro acima de 1,5x o período do vsync no soak de 5 min** e p95 do **tempo de CPU do quadro** abaixo de 8 ms (orçamento a 120 Hz) em release. O tempo de CPU real exige Instruments ou alvo sem vsync; até lá o resultado é `(?)`.
2. **Teto de `.apk` proposto: 12 MB** para o release arm64 com stdlib estática e `strip` (8,5 MB medidos + folga de ~40 % para miniaudio, texturas de teste e Vulkan/VMA). O teto de 18 MB do rascunho vinha sem fonte e deixa de valer. **É proposta ao dono**; o debug (30,7 MB) fica fora do critério. Reabrir se Foundation completo ou ICU entrarem no Android.
3. **Quatro números `(?)` do brief da Onda 1 passam a medidos:** layout de 1 000 nós = 49,9 µs no S22+ (alvo da U-1a < 1 ms confirmado com folga de 20x); compilação incremental 1,4 a 1,8 s; `.apk` 8,5 MB; ΔRSS de 50 ciclos no iPhone 0,016 MB.
4. **R-1 em Android não precisa parar:** o kill-criteria do brief (vazamento ou p95 ruim em aparelho) **não** disparou em nenhum aparelho medido. A parte Android continua dependente da V-1, não de correção.

## Pendente
- 50 ciclos de background/resume/rotação e soak no S22+ (V-1, ADR 0024).
- SIL do `Query` e das consultas de handle sem alocação (A-1, ADR 0021).
- Custo de CPU real por quadro e ProMotion a 120 Hz no iPhone `(?)`; medir em Release.
- Aliasing por heap no Metal (R-1, ADR 0023) e custo de binário do miniaudio (AU-1).
- Medições foram feitas em build Debug no iPhone e com a cena trivial da demo; refazer no vertical slice.

## Quando reabrir
Se um número do vertical slice divergir muito destas linhas de base, ou se o teto do `.apk` for rejeitado pelo dono.

# ADR 0003: ECS híbrido e agendador single-thread primeiro

**Status:** Aceito.

## Decisão
- **ECS 100 % Swift.** Flecs foi considerado e retirado; serve só como régua de benchmark (meta ≤ 1,2× do C).
- **Armazenamento híbrido:** arquétipos SoA + sparse/bitset para *tags* (arquétipo puro obrigaria copiar a entidade a cada `Dead`/`Stunned`).
- **PoC de `Query` com parameter packs** e inspeção de SIL (zero `swift_allocObject`, sem witness tables) **antes** de congelar a API. Fallback: overloads gerados de aridade 1..8.
- **Agendador single-thread correto primeiro**, já validando o **grafo de acesso Read/Write no registro** dos sistemas. O pool work-stealing próprio só entra quando benchmark provar ganho líquido. Swift Concurrency fica nas bordas (I/O, rede, assets).
- Regra e teste de CI: **sem estado global mutável escondido** em sistemas, para que paralelizar depois seja troca de executor e não de API.

## Motivos
Otimização prematura de um pool é risco no caminho crítico; a meta de 100 mil entidades em < 2 ms deve ser viável em uma thread (a medir); big.LITTLE e ARC compartilhado podem anular o ganho.

## Quando reabrir
Quando benchmarks de animação/transform/skinning mostrarem ganho de paralelismo interno ou do agendador geral.

# ADR 0027: Formato de pose em espaço do modelo, arena e fronteira com R-1b (AN-1)

**Status:** Proposto (implementado na trilha AN-1; complementa o [ADR 0023](0023-mundo-de-render-e-extracao.md) proposto para R-1). Datas em 2026-11-15.

## Contexto
O [ADR 0023](0023-mundo-de-render-e-extracao.md) e o contrato [r-1-contrato.md](../briefs/r-1-contrato.md) (§7.2) definiram em alto nível que o `CajuAnim` (AN-1) entrega poses de *skinning* em espaço do modelo sem multiplicar pelo `inverseBind`, e que a referência da pose e sua arena residem em `CajuScene` para evitar dependência de `CajuAnim` em `CajuRender`. Faltava fechar o formato binário/de API da pose, a política de alocação da arena, o limite de juntas, o modelo de entrada (sem glTF ainda) e o mecanismo de *cull* fora da tela.

## Decisão
- **Referência no ECS (`CajuSkinPose` em `CajuScene`, ID 9 `(?)`):** `struct` `CajuComponent` (`BitwiseCopyable`, ~12 bytes) com `poseSlot: UInt32` (índice inicial em matrizes `CajuMat4` na arena), `jointCount: UInt16` e `version: UInt32`. A cada escrita válida na arena, `version` é incrementado (`&+= 1`), permitindo que o R-1b copie apenas poses alteradas.
- **Arena contígua (`CajuPoseArena` em `CajuScene`):** `final class` dona de um `ContiguousArray<CajuMat4>` único pré-alocado no `init`, com faixas livres coalescentes também pré-reservadas (`ceil(matrixCapacity / 2)`), garantindo **zero alocação no quadro estável** tanto em `allocate`/`release` quanto em escrita/leitura direta por buffer (`UnsafeBufferPointer`/`UnsafeMutableBufferPointer`). Estouro de capacidade retorna `CajuPoseArena.ArenaError.capacityExceeded`, nunca crescimento silencioso.
- **Formato e convenção das matrizes:** `CajuMat4` em ordem de colunas (`CajuMath`), representando a transformação acumulada da raiz do esqueleto até cada junta em **espaço do modelo** (`model[j] = model[parent] * local[j]`, raízes `parent == -1` com `model[j] = local[j]`), **sem `inverseBind`**. A multiplicação por `inverseBind[j]` fica exclusivamente no R-1b (após *cull* de frustum no render).
- **Limite de juntas no MVP:** `128` juntas por esqueleto (`CajuPoseArena.maxJointCount = 128 (?)`), permitindo representar máscaras por junta em `CajuJointMask` com dois `UInt64` (16 bytes, `BitwiseCopyable`, sem alocação) e *scratch buffers* fixos de 128 elementos em `CajuAnimScratchBuffer`.
- **Clipes e hierarquia no AN-1:** clipes (`CajuAnimClip`) construíveis em código com canais separados por tipo (translação/escala `CajuVec3`, rotação `CajuQuat` normalizado na entrada) e interpolação `.linear` (`lerp`/`slerp` pelo menor arco) ou `.step`; carga a partir de glTF entra depois via A-1/A-1b. `CajuSkeleton` aceita juntas em qualquer ordem e pré-computa a ordenação topológica na criação (rejeitando ciclos com erro tipado).
- **Cull fora da tela:** `CajuAnimPlayback` (ID 16) e `CajuAnimPlayer` expõem a *flag* `isCulled: Bool`, e `CajuAnim.poseUpdateSystem` aceita adicionalmente um *hook* `shouldSample` (e `CajuQueryFilter`) para pular amostragem SIMD, propagação hierárquica e escrita na arena sem tocar `pose.version` (o relógio continua avançando por padrão quando `advanceTimeWhenCulled == true`).

## Alternativas
- **Paleta inline no componente ECS:** ~8 KB (`128 × 64` bytes) por linha da coluna SoA degradaria localidade de cache em consultas e cópias de arquétipo.
- **Juntas como entidades ECS com `CajuTransform`:** alto custo de entidades por personagem e propagação por níveis em vez de laço SIMD contíguo de `≤ 128` matrizes.
- **Faixas fixas de 128 matrizes por slot na arena:** simplificaria o alocador, mas desperdiçaria memória para esqueletos menores (ex.: 24–32 juntas); faixas variáveis com coalescência mantêm O(1) na leitura do R-1b (`poseSlot` já é o deslocamento direto).
- **Multiplicar `inverseBind` no AN-1:** acoplaria o esqueleto animado à malha específica e desperdiçaria trabalho para malhas fora do frustum.

## Consequências
- `CajuScene` passa a hospedar `CajuSkinPose` (componente ID 9 `(?)`) e `CajuPoseArena` sem depender de `CajuAnim` nem `CajuRender`.
- `CajuAnim` mantém zero dependências de render/GPU e zero Foundation; testa-se puro em Linux e macOS.
- O R-1b já tem contrato binário fechado para ler `CajuPoseArena` e multiplicar por `inverseBind` apenas quando `CajuSkinPose.version` mudar.
- Mudar o limite de `128` juntas ou o layout da arena após R-1b/A-1 consumirem exige novo ADR.

## Quando reabrir
- Se personagens do jogo ou *vertical slice* exigirem `> 128` juntas por esqueleto ou *blend shapes* (além do MVP).
- Se o custo de `CajuAnim.poseUpdateSystem` estourar o orçamento de CPU no iPhone 16 Pro ou Galaxy S22+ `(?)` e exigir *jobs* paralelos por esqueleto (usando `CajuAnimScratchBuffer` por *worker*).
- Se a fragmentação de faixas variáveis na `CajuPoseArena` se mostrar relevante sob *spawn*/*despawn* intenso (trocar internamente para *slab* por faixas de tamanho sem quebrar a API pública).

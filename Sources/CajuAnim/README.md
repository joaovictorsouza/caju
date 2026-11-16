# CajuAnim

Clipes, player, *crossfade*, máscaras por junta e amostragem SIMD de animação esquelética (trilha AN-1).

- **Camada:** 3 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** AN-1 (Onda 1).
- **Estado:** implementado em código puro (clipes construíveis em código; carga via glTF entra pela trilha A-1).
- **Decisões:** [ADR 0023](../../docs/adr/0023-mundo-de-render-e-extracao.md) (proposto) e [ADR 0027](../../docs/adr/0027-formato-de-pose-e-fronteira-r1b.md) (proposto).

## Arquitetura e fronteira com R-1b
- O `CajuAnim` entrega **poses em espaço do modelo sem `inverseBind`**; o `CajuRender` (R-1b) multiplica pelo `inverseBind` da malha após o *cull* de frustum.
- `CajuSkinPose` (componente `CajuCore` de ID `9` `(?)`, `BitwiseCopyable`, ~12 bytes) e `CajuPoseArena` (arena contígua de `CajuMat4` com capacidade reservada e faixas livres coalescentes) residem em `CajuScene`, evitando dependência entre `CajuAnim` e `CajuRender`.
- Limite de juntas no MVP: `128` (`CajuAnim.maxJointCount` / `CajuPoseArena.maxJointCount`) `(?)`.

## API principal
- **Esqueleto:** `CajuJointTransform` (TRS local + `blend`) e `CajuSkeleton` (valida parentescos, rejeita ciclos com `CajuAnimError.cycleDetected` e pré-computa `evaluationOrder` topológica).
- **Clipes e canais:** `CajuAnimClip`, `CajuAnimChannel`, `CajuAnimVec3Channel`, `CajuAnimQuatChannel`, `CajuAnimInterpolation` (`.linear` com `lerp`/`slerp` pelo menor arco e `.step`). Quaternions são normalizados na entrada e na amostragem.
- **Máscaras:** `CajuJointMask` (`BitwiseCopyable`, 2× `UInt64`, 128 juntas, com `CajuJointMask.subtree(of:rootJoint:)`).
- **Player e ECS:** `CajuAnimPlayback` (componente `CajuCore` de ID `16`, `BitwiseCopyable`), `CajuAnimPlayer`, `CajuAnimLibrary` e `CajuAnim.poseUpdateSystem(...)`.
- **Amostragem SIMD sem alocação:** `CajuAnimScratchBuffer` pré-alocado + `CajuAnimSampler` (`sampleLocalPose`, `blendLocalPoses`, `computeModelPose`, `sampleAndWrite`, `sampleCrossfadeAndWrite`).
- **Cull fora da tela:** *flag* `isCulled` em `CajuAnimPlayback`/`CajuAnimPlayer` e *hook* `shouldSample` em `CajuAnim.poseUpdateSystem` e `CajuAnimPlayer.sampleAndWrite` para pular amostragem, propagação e escrita na arena sem incrementar `pose.version`.

## Dependências
- `CajuCore`
- `CajuMath`
- `CajuScene`

## Como testar e benchmark
```sh
swift test --filter CajuAnim
```
- `Tests/CajuModulesTests/CajuAnimTests.swift`: testes unitários, de integração ECS e de propriedade com semente fixa (`CajuFuzz.run`, 10 000 iterações: extremos de interpolação, normalização de `CajuQuat`, soma de pesos do *crossfade* = 1 e isolamento por `CajuJointMask`).
- `Tests/CajuModulesTests/CajuAnimBenchmarkTests.swift`: benchmark de amostragem SIMD + propagação + escrita na arena para `32` e `128` juntas `(?)`; metas de aparelho permanecem `(?)` até medição em iPhone 16 Pro e Galaxy S22+.

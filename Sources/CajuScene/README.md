# CajuScene

Transform, hierarquia e cena sobre o ECS.

- **Camada:** 3 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** TB-1.
- **Estado:** `CajuTransform`, `CajuGlobalTransform`, `CajuParent` e propagação de transform implementados.

## API
- Componentes (IDs 0–2 do `CajuCore`): `CajuTransform` (TRS local), `CajuGlobalTransform` (matriz de mundo), `CajuParent` (pai + profundidade).
- `world.spawnNode(_:parent:)`, `setParent(_:to:)` (recusa ciclos e pai inexistente; recalcula profundidades), `parent(of:)`, `children(of:)`, `globalMatrix(of:)`, `despawnSubtree(_:)`.
- `CajuScene.transformPropagation()`: sistema do estágio `postUpdate` (lê `CajuTransform`/`CajuParent`, escreve `CajuGlobalTransform`); pai antes do filho por nível de profundidade; pai despawnado = nó raiz.

## Limites conhecidos
- `CajuTransform` guarda `SIMD` (e não `CajuVec3`/`CajuQuat`) até o `CajuMath` conformar a `BitwiseCopyable` (ADR 0014).
- A propagação percorre o conjunto de nós com pai uma vez por nível de profundidade (sem *dirty flags* ainda); `children(of:)` é O(n) e aloca (caminho frio).

## Dependências
- `CajuCore`
- `CajuMath`

## Como testar
`swift test` (alvo `CajuSceneTests`).

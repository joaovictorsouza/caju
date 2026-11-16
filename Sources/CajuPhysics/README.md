# CajuPhysics

Consultas espaciais no ECS (raycast, sobreposição, varredura de esfera, picking) e movimento cinemático simples.

- **Camada:** 3 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** PH-1 (Onda 1).
- **Estado:** consultas e kinematic implementados. **Física dinâmica** (corpos rígidos, colisão com resposta, restrições) fica fora: Onda 2, módulo opcional por *trait*.

## API
- `CajuCollider` (componente ID 24): `.box(halfExtents:center:layers:)` e `.sphere(radius:center:layers:)` no espaço local do nó; escala não uniforme respeitada no raycast.
- `CajuKinematicBody` (ID 25) + `CajuPhysics.kinematicSystem()` (estágio `update`): integra velocidade linear e angular no `CajuTransform`.
- `CajuPhysicsScene`: índice dos colliders do `CajuWorld` sobre `CajuBVH`.
  - `sync(world:)` ou `syncSystem(world:)` (estágio `postUpdate`, depois de `CajuScene.transformPropagation`): insere, atualiza e remove proxies a partir de `CajuCollider` + `CajuGlobalTransform`.
  - `raycast(_:maxDistance:layerMask:)` (primeiro impacto), `raycastAll(_:…visitor:)`, `overlapSphere(_:layerMask:visitor:)`, `spherecast(_:displacement:layerMask:)` e `pick(pointer:viewportSize:inverseViewProjection:…)`. Resultado: `CajuPhysicsHit` (entidade, `t`, ponto, normal no mundo).
- `CajuPicking.ray(...)`: raio de mundo a partir de `CajuPointerEvent`, `CajuPointerSnapshot` ou `CajuVec2` em pontos lógicos (origem da tela no canto superior esquerdo; profundidade `[0, 1]`).

## Contrato e limites
- `t` do raio está em unidades de `ray.direction`; em `spherecast`, `t` é fração `0...1` do deslocamento.
- Origem dentro do volume: impacto em `t = 0` com normal `-direção`.
- Sem alocação por consulta (pilha de travessia reutilizada); `sync` pode alocar. Não é thread-safe.
- `overlapSphere` é exata para movimento rígido e escala uniforme; com escala não uniforme é conservadora (esfera) ou aproximada (caixa). `spherecast` contra caixa infla a caixa (conservador em arestas e cantos).
- `raycast` não encurta o raio pela BVH: visita todas as AABBs atingidas (otimização futura, medir antes).
- `syncSystem` captura o `CajuWorld`, pois o contexto de sistema não expõe entidades.
- Colliders inválidos (não finitos ou tamanho negativo) e matrizes não invertíveis são ignorados.

## Dependências
- `CajuCore`, `CajuMath`, `CajuPhysicsSpatial`, `CajuScene`, `CajuInput`

## Como testar
`swift test --filter CajuPhysicsTests`: força bruta contra a fase estreita independente do `CajuMath` em mundo hierárquico, camadas, picking com `CajuPointerEvent`, kinematic, ciclo de vida das entidades e contagem de `malloc` (macOS).

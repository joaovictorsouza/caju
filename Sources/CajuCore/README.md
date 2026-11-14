# CajuCore

ECS, agendador, tempo e mensagens. (Log ainda não implementado; fora do escopo da TB-1.)

- **Camada:** 0 (dependências só para baixo; ver §5 do plano). Sem Foundation.
- **Trilha dona:** TB-1. Decisões: [ADR 0003](../../docs/adr/0003-ecs-e-agendador.md) e [ADR 0014](../../docs/adr/0014-ecs-query-e-component.md).
- **Estado:** implementado (ECS híbrido, `Query`, agendador, mensagens, estados, tempo).

## API
- **Entidades/componentes:** `CajuEntity` (índice + geração), `CajuComponent` (`BitwiseCopyable`, `static componentID`), `CajuTag` (bitset por entidade), `CajuComponentMask`.
- **Mundo:** `CajuWorld` — `spawn(_ componentes...)`, `despawn`, `get/set/has`, `insert/remove` (move de arquétipo), `addTag/removeTag/hasTag`, `forEachEntity(having:)`, `reserve(entities:)`. Erros: `CajuWorldError` (`throws(E)` tipado).
- **Consulta:** `world.forEach(CajuWrite<A>.self, CajuRead<B>.self, filter:) { a, b in … }`, aridade 1..8 (gerada); `CajuQueryFilter` (sem componentes, com/sem *tags*). `forEachPack` para aridade > 8. Mudança estrutural dentro da consulta é recusada.
- **Agendador:** `CajuScheduler` + `CajuSystemDescriptor` (estágio, `reads`, `writes`, `after`). `build()` valida nomes/ciclos e calcula a ordem; `tick(delta:)` roda `first, fixedUpdate (0..N), preUpdate, update, postUpdate, last`. `CajuSystemContext.forEach/get/set` validam o acesso declarado (`CajuAccessError`). Comandos estruturais por `CajuCommandBuffer` (aplicados entre estágios).
- **Suporte:** `CajuTime`, `CajuFixedTimestep`, `CajuMessageQueue<M>` (buffer duplo, capacidade fixa), `CajuStateMachine<S>` (transição adiada).

## Exemplo
```swift
@Component(id: 48) struct Position { var x, y: Float }  // gera `: CajuComponent` e `componentID`
@Component(id: 49) struct Velocity { var x, y: Float }
// Equivalente manual: struct X: CajuComponent { static let componentID = CajuComponentID(50) }

let world = CajuWorld()
_ = try world.spawn(Position(x: 0, y: 0), Velocity(x: 1, y: 0))
let scheduler = CajuScheduler(world: world)
try scheduler.add(
    CajuSystemDescriptor(
        name: "integrate", reads: CajuComponentMask(Velocity.componentID),
        writes: CajuComponentMask(Position.componentID)
    ) { ctx throws(CajuAccessError) in
        let dt = Float(ctx.time.delta)
        try ctx.forEach(CajuWrite<Position>.self, CajuRead<Velocity>.self) { p, v in
            p.value.x += v.x * dt
        }
    })
try scheduler.build()
try scheduler.tick(delta: 1.0 / 60.0)
```

## Faixas de `componentID` (0..<64) e *tags*
0–15 núcleo (`CajuScene` usa 0–2) · 16–47 demais módulos da engine · 48–63 jogo. *Tags* têm espaço próprio (0..<64).

## Limites conhecidos
- Máx. 64 componentes e 64 *tags*; componentes `BitwiseCopyable`.
- `@Component(id:)` (macro, [ADR 0020](../../docs/adr/0020-macro-component.md)) gera só a conformância e o `componentID`; o ID continua manual e único (conflito detectado pelo mundo). Declarar `static let componentID` à mão segue válido. A macro vive em `Sources/CajuMacrosPlugin` (alvo `.macro`, `swift-syntax` fixado; roda no host).
- Sem estado global mutável escondido: tudo vive em `CajuWorld`/`CajuScheduler`/filas passadas explicitamente. O agendador é single-thread; só o laço principal acessa o mundo.
- `CajuQueryArity.swift` é gerado: `python3 docs/tools/gen-query-overloads.py`.

## Desempenho (macOS arm64, `-O`; números de runner, não de aparelho (?))
`swift run -c release caju-bench` (suíte `CajuCore`): consulta 3 componentes ≈ 3,7 ns/entidade (100 mil entidades ≈ 0,37 ms; meta NFR-008 < 2 ms no aparelho alto (?)), `spawn` ≈ 199 ns (≈ 5 M/s; meta ≥ 1 M/s), versão com packs ≈ 38,7 ns/entidade.

## Dependências
- nenhuma

## Como testar
`swift test` (alvo `CajuCoreTests`) e `swift test --sanitize=thread`. SIL do `Query`: comando no ADR 0014.

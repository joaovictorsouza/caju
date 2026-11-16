# CajuInput

Toque, ponteiro unificado, reconhecedores de gestos e integração ao ECS por mensagens.

- **Camada:** 3 (dependências só para baixo; ver §5 do plano). Sem Foundation.
- **Trilha dona:** I-1 (Onda 1).
- **Estado:** implementado (ponteiro unificado, tabela de ponteiros, reconhecedores puros, `CajuInputProcessor`, fila em anel e despacho para `CajuCore.CajuMessageQueue`).

## Peças
- **Ponteiro bruto unificado (`CajuPointerEvent.swift`):** `CajuPointerID`, `CajuPointerKind` (`.touch`, `.mouse`, `.stylus`), `CajuPointerPhase` (`began`, `moved`, `ended`, `cancelled`), `CajuPointerButtonMask`, `CajuPointerEvent` (posição em pontos lógicos, `timestamp` monotônico, `BitwiseCopyable & Sendable`), `CajuPointerSnapshot` e `CajuPointerTable` (capacidade fixa pré-alocada; trata ponteiros duplicados, desconhecidos, coordenadas não finitas e estouro de capacidade sem crash).
  - `CajuPointerEvent(touch:scale:timestamp:)` converte `CajuPlatform.CajuTouchEvent` (em pixels) para pontos lógicos.
- **Gestos e fila em anel (`CajuGestureEvent.swift`):** `CajuGesturePhase`, `CajuTapGesture`, `CajuLongPressGesture`, `CajuPanGesture`, `CajuPinchGesture`, `CajuGestureEvent` (`BitwiseCopyable & Sendable`) e `CajuGestureQueue` (anel de capacidade fixa pré-alocada no `init`, estilo `CajuEventQueue`, FIFO estrito em O(1) com `droppedCount` quando cheia).
- **Reconhecedores puros (`CajuGestureRecognizers.swift`):** `CajuGestureConfiguration` (limiares sanitizados: `tapSlop`, `tapMaximumDuration`, `multiTapInterval`, `multiTapSlop`, `longPressDuration`, `longPressSlop`, `panThreshold`, `pinchThreshold`, `pinchMinimumSpan`, `allowPanDuringPinch`), `CajuTapRecognizer`, `CajuLongPressRecognizer` (com `advance(to:)` por tempo injetado), `CajuPanRecognizer` e `CajuPinchRecognizer`.
- **Processador e ECS (`CajuInputProcessor.swift`, `CajuInput.swift`):** `CajuInputProcessor` coordena `CajuPointerTable`, os 4 reconhecedores e `CajuGestureQueue`, despachando mensagens para `CajuCore.CajuMessageQueue<CajuGestureEvent>` via `flush(into:)` (aliases `CajuGestureMessageQueue` e `CajuPointerMessageQueue`).

## Exemplo
```swift
let gestureMessages = CajuGestureMessageQueue(capacity: 64)
var processor = CajuInputProcessor()

// No laço principal (antes de rodar o CajuScheduler):
processor.process(pointerEvent)
processor.advance(to: frameTimestamp)
processor.flush(into: gestureMessages)
gestureMessages.swap()

// Dentro de um sistema no CajuScheduler:
gestureMessages.forEachMessage { message in
    switch message {
    case .tap(let tap): ...
    case .longPress(let press): ...
    case .pan(let pan): ...
    case .pinch(let pinch): ...
    }
}
```

## Decisões e limites conhecidos
- **Integração ao ECS:** utiliza `CajuCore.CajuMessageQueue<M>` diretamente (`CajuGestureEvent` e `CajuPointerEvent` são `BitwiseCopyable & Sendable`), sem estado global nem componente dedicado.
- **Relação com `CajuPlatform`:** `CajuPlatformEvent` ainda não carrega eventos de toque/ponteiro; a ponte imediata é `CajuPointerEvent(touch:scale:timestamp:)` a partir de `CajuTouchEvent`. O modelo de eventos de `CajuPlatform` não foi alterado (ADR 0025 não necessário).
- **Capacidades fixas:** `CajuPointerTable` usa capacidade pré-alocada (padrão `16`); os reconhecedores isolados rastreiam até `16` ponteiros simultâneos inline (`CajuInlinePointerIDSet`); `CajuGestureQueue` tem capacidade padrão `64`.
- **Tempo injetado:** nenhum reconhecedor lê relógio global; testes e laço de jogo dirigem o tempo via `CajuTimestamp`.

## Caminho quente e verificação sem alocação
Verificado por inspeção do SIL gerado em modo *release* (`swift build -c release --target CajuInput` e `swiftc -O -wmo -emit-sil` sobre os fontes do módulo e sobre um chamador externo):
- `0` ocorrências de `alloc_ref`, `alloc_box`, `swift_allocObject` e `witness_method` em `CajuInputProcessor.process(_:)`, `CajuInputProcessor.process(_:scale:timestamp:)`, `CajuInputProcessor.advance(to:)`, `CajuInputProcessor.flush(into:)`, `CajuInputProcessor.popGesture()`, `CajuGestureQueue.push(_:)`, `CajuGestureQueue.pop()`, `CajuGestureQueue.flush(into:)`, `CajuPointerTable.apply(_:)` e nos métodos `process(_:)` / `advance(to:)` dos 4 reconhecedores.
- Como `CajuGestureQueue` e `CajuPointerTable` são `struct`s com `ContiguousArray` pré-alocado no `init`, a mutação em dono único (padrão do laço principal) não aloca; o único caminho de alocação presente no SIL é a proteção padrão de *copy-on-write* caso o valor seja copiado e mutado de forma compartilhada.
- Latência e orçamento em aparelho de referência (iPhone 16 Pro / Galaxy S22+): `(?)` (não medido em hardware).

## Dependências
- `CajuCore`
- `CajuMath`
- `CajuPlatform`

## Como testar
`swift test --filter CajuInput` (testes em `Tests/CajuModulesTests/CajuInputTests.swift`, incluindo máquinas de estado com sequências sintéticas, integração com `CajuScheduler` e *fuzz* determinístico com `CajuFuzz`).

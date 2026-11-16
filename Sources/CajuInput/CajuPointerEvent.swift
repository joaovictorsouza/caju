import CajuMath
import CajuPlatform

/// Identificador estável de um dedo ou ponteiro ativo durante o seu ciclo de vida.
public struct CajuPointerID: RawRepresentable, BitwiseCopyable, Sendable, Hashable, Comparable,
    ExpressibleByIntegerLiteral
{
    public var rawValue: UInt64

    @inlinable public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    @inlinable public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    @inlinable public init(integerLiteral value: UInt64) {
        self.rawValue = value
    }

    /// Converte um identificador de ponteiro vindo de `CajuTouchEvent` (Android).
    @inlinable public init(androidPointerID: Int32) {
        self.rawValue = UInt64(bitPattern: Int64(androidPointerID))
    }

    @inlinable public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Origem física de um evento de ponteiro unificado.
public enum CajuPointerKind: UInt8, BitwiseCopyable, Sendable, Equatable, Hashable {
    case touch
    case mouse
    case stylus
}

/// Fase do ciclo de vida de um ponteiro ativo.
public enum CajuPointerPhase: UInt8, BitwiseCopyable, Sendable, Equatable, Hashable {
    case began
    case moved
    case ended
    case cancelled

    /// Converte a fase de toque da camada `CajuPlatform`.
    @inlinable public init(_ touchPhase: CajuTouchPhase) {
        switch touchPhase {
        case .began: self = .began
        case .moved: self = .moved
        case .ended: self = .ended
        case .cancelled: self = .cancelled
        }
    }
}

/// Máscara de botões pressionados em um evento de ponteiro unificado.
public struct CajuPointerButtonMask: OptionSet, BitwiseCopyable, Sendable, Equatable, Hashable {
    public let rawValue: UInt8

    @inlinable public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let primary = Self(rawValue: 1 << 0)
    public static let secondary = Self(rawValue: 1 << 1)
    public static let auxiliary = Self(rawValue: 1 << 2)
}

/// Evento bruto de toque ou ponteiro unificado, em pontos lógicos.
///
/// É um tipo de valor `BitwiseCopyable` e `Sendable`: pode cruzar fronteiras sem ARC e entrar
/// diretamente em `CajuMessageQueue<CajuPointerEvent>`.
///
/// ```swift
/// let event = CajuPointerEvent(
///     pointerID: 1,
///     phase: .began,
///     position: CajuVec2(120, 240),
///     timestamp: CajuTimestamp(seconds: 1.0)
/// )
/// ```
public struct CajuPointerEvent: BitwiseCopyable, Sendable, Equatable {
    public var pointerID: CajuPointerID
    public var kind: CajuPointerKind
    public var phase: CajuPointerPhase
    /// Posição em pontos lógicos da superfície.
    public var position: CajuVec2
    public var buttons: CajuPointerButtonMask
    /// Instante monotônico em nanossegundos (`CajuTimestamp.nanoseconds`).
    public var timestampNanoseconds: UInt64

    @inlinable public var timestamp: CajuTimestamp {
        get { CajuTimestamp(nanoseconds: timestampNanoseconds) }
        set { timestampNanoseconds = newValue.nanoseconds }
    }

    @inlinable public init(
        pointerID: CajuPointerID,
        kind: CajuPointerKind = .touch,
        phase: CajuPointerPhase,
        position: CajuVec2,
        buttons: CajuPointerButtonMask = .primary,
        timestamp: CajuTimestamp
    ) {
        self.pointerID = pointerID
        self.kind = kind
        self.phase = phase
        self.position = position
        self.buttons = buttons
        self.timestampNanoseconds = timestamp.nanoseconds
    }

    /// Converte um `CajuTouchEvent` (em pixels) da camada `CajuPlatform` para pontos lógicos.
    ///
    /// Escalas não positivas ou não finitas assumem `1.0` para evitar divisão inválida.
    @inlinable public init(touch: CajuTouchEvent, scale: Float, timestamp: CajuTimestamp) {
        let safeScale = (scale > 0 && scale.isFinite) ? scale : 1.0
        self.pointerID = CajuPointerID(androidPointerID: touch.pointerID)
        self.kind = .touch
        self.phase = CajuPointerPhase(touch.phase)
        self.position = CajuVec2(touch.x / safeScale, touch.y / safeScale)
        self.buttons = (touch.phase == .ended || touch.phase == .cancelled) ? [] : .primary
        self.timestampNanoseconds = timestamp.nanoseconds
    }
}

/// Estado instantâneo de um ponteiro ativo rastreado por `CajuPointerTable`.
public struct CajuPointerSnapshot: BitwiseCopyable, Sendable, Equatable {
    public var pointerID: CajuPointerID
    public var kind: CajuPointerKind
    public var buttons: CajuPointerButtonMask
    public var startPosition: CajuVec2
    public var previousPosition: CajuVec2
    public var position: CajuVec2
    public var startTimestampNanoseconds: UInt64
    public var lastTimestampNanoseconds: UInt64

    @inlinable public var startTimestamp: CajuTimestamp {
        CajuTimestamp(nanoseconds: startTimestampNanoseconds)
    }

    @inlinable public var lastTimestamp: CajuTimestamp {
        CajuTimestamp(nanoseconds: lastTimestampNanoseconds)
    }

    @inlinable public init(
        pointerID: CajuPointerID,
        kind: CajuPointerKind,
        buttons: CajuPointerButtonMask,
        startPosition: CajuVec2,
        previousPosition: CajuVec2,
        position: CajuVec2,
        startTimestampNanoseconds: UInt64,
        lastTimestampNanoseconds: UInt64
    ) {
        self.pointerID = pointerID
        self.kind = kind
        self.buttons = buttons
        self.startPosition = startPosition
        self.previousPosition = previousPosition
        self.position = position
        self.startTimestampNanoseconds = startTimestampNanoseconds
        self.lastTimestampNanoseconds = lastTimestampNanoseconds
    }
}

/// Motivo pelo qual um evento bruto foi descartado pela tabela de ponteiros.
public enum CajuPointerDropReason: UInt8, BitwiseCopyable, Sendable, Equatable {
    case nonFinitePosition
    case unknownPointer
    case capacityExceeded
}

/// Resultado da aplicação de um evento bruto na tabela de ponteiros ativos.
public enum CajuPointerTransition: BitwiseCopyable, Sendable, Equatable {
    case began(CajuPointerSnapshot)
    /// Um `began` chegou para um `pointerID` já ativo; cancela o anterior e inicia o novo.
    case restarted(previous: CajuPointerSnapshot, current: CajuPointerSnapshot)
    case moved(CajuPointerSnapshot)
    case ended(CajuPointerSnapshot)
    case cancelled(CajuPointerSnapshot)
    case ignored(CajuPointerDropReason)
}

/// Tabela de capacidade fixa pré-alocada que rastreia ponteiros ativos sem alocar após o `init`.
public struct CajuPointerTable: Sendable, Equatable {
    private struct Slot: BitwiseCopyable, Sendable, Equatable {
        var occupied: Bool
        var snapshot: CajuPointerSnapshot

        static let empty = Slot(
            occupied: false,
            snapshot: CajuPointerSnapshot(
                pointerID: 0,
                kind: .touch,
                buttons: [],
                startPosition: .zero,
                previousPosition: .zero,
                position: .zero,
                startTimestampNanoseconds: 0,
                lastTimestampNanoseconds: 0
            )
        )
    }

    private var slots: ContiguousArray<Slot>
    public private(set) var count: Int = 0
    public private(set) var droppedCount: Int = 0

    public var capacity: Int { slots.count }
    public var isEmpty: Bool { count == 0 }

    public init(capacity: Int = 16) {
        let clamped = max(1, capacity)
        self.slots = ContiguousArray(repeating: .empty, count: clamped)
    }

    /// Consulta o estado atual de um ponteiro ativo.
    public func snapshot(for pointerID: CajuPointerID) -> CajuPointerSnapshot? {
        for i in 0..<slots.count where slots[i].occupied && slots[i].snapshot.pointerID == pointerID {
            return slots[i].snapshot
        }
        return nil
    }

    /// Itera sobre todos os ponteiros ativos sem alocar.
    public func forEachActive(_ body: (CajuPointerSnapshot) -> Void) {
        for i in 0..<slots.count where slots[i].occupied {
            body(slots[i].snapshot)
        }
    }

    /// Aplica um evento de ponteiro à tabela mantendo invariantes de contagem e monotonicidade.
    public mutating func apply(_ event: CajuPointerEvent) -> CajuPointerTransition {
        guard event.position.isFinite else {
            droppedCount += 1
            return .ignored(.nonFinitePosition)
        }

        let existingIndex = indexOf(event.pointerID)

        switch event.phase {
        case .began:
            let fresh = CajuPointerSnapshot(
                pointerID: event.pointerID,
                kind: event.kind,
                buttons: event.buttons,
                startPosition: event.position,
                previousPosition: event.position,
                position: event.position,
                startTimestampNanoseconds: event.timestampNanoseconds,
                lastTimestampNanoseconds: event.timestampNanoseconds
            )
            if let index = existingIndex {
                let previous = slots[index].snapshot
                slots[index].snapshot = fresh
                return .restarted(previous: previous, current: fresh)
            }
            guard let freeIndex = firstFreeIndex() else {
                droppedCount += 1
                return .ignored(.capacityExceeded)
            }
            slots[freeIndex].occupied = true
            slots[freeIndex].snapshot = fresh
            count += 1
            return .began(fresh)

        case .moved:
            guard let index = existingIndex else {
                return .ignored(.unknownPointer)
            }
            var snap = slots[index].snapshot
            snap.previousPosition = snap.position
            snap.position = event.position
            snap.buttons = event.buttons
            if event.timestampNanoseconds > snap.lastTimestampNanoseconds {
                snap.lastTimestampNanoseconds = event.timestampNanoseconds
            }
            slots[index].snapshot = snap
            return .moved(snap)

        case .ended:
            guard let index = existingIndex else {
                return .ignored(.unknownPointer)
            }
            var snap = slots[index].snapshot
            snap.previousPosition = snap.position
            snap.position = event.position
            snap.buttons = event.buttons
            if event.timestampNanoseconds > snap.lastTimestampNanoseconds {
                snap.lastTimestampNanoseconds = event.timestampNanoseconds
            }
            slots[index].occupied = false
            count -= 1
            return .ended(snap)

        case .cancelled:
            guard let index = existingIndex else {
                return .ignored(.unknownPointer)
            }
            var snap = slots[index].snapshot
            snap.previousPosition = snap.position
            snap.position = event.position
            snap.buttons = event.buttons
            if event.timestampNanoseconds > snap.lastTimestampNanoseconds {
                snap.lastTimestampNanoseconds = event.timestampNanoseconds
            }
            slots[index].occupied = false
            count -= 1
            return .cancelled(snap)
        }
    }

    /// Remove todos os ponteiros ativos sem desalocar o armazenamento interno.
    public mutating func clear() {
        for i in 0..<slots.count {
            slots[i].occupied = false
        }
        count = 0
    }

    private func indexOf(_ pointerID: CajuPointerID) -> Int? {
        for i in 0..<slots.count where slots[i].occupied && slots[i].snapshot.pointerID == pointerID {
            return i
        }
        return nil
    }

    private func firstFreeIndex() -> Int? {
        for i in 0..<slots.count where !slots[i].occupied {
            return i
        }
        return nil
    }
}

/// Conjunto fixo inline (sem alocação em heap) de até 16 IDs de ponteiro para máquinas de estado.
@usableFromInline
struct CajuInlinePointerIDSet: BitwiseCopyable, Sendable, Equatable {
    @usableFromInline static let maxCount = 16

    @usableFromInline var s0: UInt64 = 0
    @usableFromInline var s1: UInt64 = 0
    @usableFromInline var s2: UInt64 = 0
    @usableFromInline var s3: UInt64 = 0
    @usableFromInline var s4: UInt64 = 0
    @usableFromInline var s5: UInt64 = 0
    @usableFromInline var s6: UInt64 = 0
    @usableFromInline var s7: UInt64 = 0
    @usableFromInline var s8: UInt64 = 0
    @usableFromInline var s9: UInt64 = 0
    @usableFromInline var s10: UInt64 = 0
    @usableFromInline var s11: UInt64 = 0
    @usableFromInline var s12: UInt64 = 0
    @usableFromInline var s13: UInt64 = 0
    @usableFromInline var s14: UInt64 = 0
    @usableFromInline var s15: UInt64 = 0
    @usableFromInline var count: UInt8 = 0

    @usableFromInline init() {}

    @usableFromInline var isEmpty: Bool { count == 0 }

    @usableFromInline func contains(_ pointerID: CajuPointerID) -> Bool {
        indexOf(pointerID) != nil
    }

    /// Insere se ainda não existir e houver espaço. Retorna `true` se entrou, `false` se já existia ou lotou.
    @discardableResult
    @usableFromInline mutating func insert(_ pointerID: CajuPointerID) -> Bool {
        if indexOf(pointerID) != nil { return false }
        let idx = Int(count)
        guard idx < Self.maxCount else { return false }
        setSlot(idx, to: pointerID.rawValue)
        count += 1
        return true
    }

    /// Remove `pointerID` se estiver presente. Retorna `true` se removeu.
    @discardableResult
    @usableFromInline mutating func remove(_ pointerID: CajuPointerID) -> Bool {
        guard let idx = indexOf(pointerID) else { return false }
        let last = Int(count) - 1
        if idx != last {
            setSlot(idx, to: getSlot(last))
        }
        setSlot(last, to: 0)
        count -= 1
        return true
    }

    @usableFromInline mutating func removeAll() {
        self = Self()
    }

    @usableFromInline func indexOf(_ pointerID: CajuPointerID) -> Int? {
        let target = pointerID.rawValue
        let n = Int(count)
        for i in 0..<n where getSlot(i) == target {
            return i
        }
        return nil
    }

    @usableFromInline func getSlot(_ index: Int) -> UInt64 {
        switch index {
        case 0: s0
        case 1: s1
        case 2: s2
        case 3: s3
        case 4: s4
        case 5: s5
        case 6: s6
        case 7: s7
        case 8: s8
        case 9: s9
        case 10: s10
        case 11: s11
        case 12: s12
        case 13: s13
        case 14: s14
        case 15: s15
        default: 0
        }
    }

    @usableFromInline mutating func setSlot(_ index: Int, to value: UInt64) {
        switch index {
        case 0: s0 = value
        case 1: s1 = value
        case 2: s2 = value
        case 3: s3 = value
        case 4: s4 = value
        case 5: s5 = value
        case 6: s6 = value
        case 7: s7 = value
        case 8: s8 = value
        case 9: s9 = value
        case 10: s10 = value
        case 11: s11 = value
        case 12: s12 = value
        case 13: s13 = value
        case 14: s14 = value
        case 15: s15 = value
        default: break
        }
    }
}

/// Identificador de uma entidade: índice no mundo + geração (detecta uso após `despawn`).
public struct CajuEntity: Hashable, Sendable, BitwiseCopyable {
    public let index: UInt32
    public let generation: UInt32

    @inlinable public init(index: UInt32, generation: UInt32) {
        self.index = index
        self.generation = generation
    }
}

/// Identificador estático de um tipo de componente ou de *tag* (0..<64).
///
/// Componentes e *tags* têm espaços de ID separados. Faixas de componentes: 0–15 núcleo
/// (`CajuScene` usa 0–2), 16–47 demais módulos da engine, 48–63 jogo (ver README do módulo).
/// IDs fora de 0..<64 são recusados no primeiro uso (`CajuWorldError.invalidComponentID`).
public struct CajuComponentID: Hashable, Sendable, BitwiseCopyable {
    public static let maxCount = 64
    public let rawValue: UInt8

    @inlinable public init(_ rawValue: UInt8) { self.rawValue = rawValue }
    @inlinable public var isValid: Bool { rawValue < 64 }
    /// Máscara de um bit; 0 se o ID for inválido.
    @inlinable public var bit: UInt64 { isValid ? (1 as UInt64) << UInt64(rawValue) : 0 }
}

/// Mesmo tipo do ID de componente, em espaço de nomes próprio (bitset por entidade).
public typealias CajuTagID = CajuComponentID

/// Dado associado a uma entidade, guardado em colunas SoA do arquétipo.
///
/// `BitwiseCopyable` é obrigatório: as colunas movem bytes sem `deinit` nem ARC.
/// O `componentID` é estático e único por tipo (a macro `@Component` o gerará no futuro; ADR 0003).
public protocol CajuComponent: BitwiseCopyable, Sendable {
    static var componentID: CajuComponentID { get }
}

/// Marcador sem dados, guardado em bitset por entidade (alternar não move a entidade de arquétipo).
public protocol CajuTag: Sendable {
    static var tagID: CajuTagID { get }
}

/// Conjunto de componentes (até 64), usado em acessos declarados e filtros.
public struct CajuComponentMask: Sendable, Equatable, BitwiseCopyable {
    public var bits: UInt64
    @inlinable public init(bits: UInt64 = 0) { self.bits = bits }
    public static let none = CajuComponentMask()

    @inlinable public init(_ ids: CajuComponentID...) {
        var b: UInt64 = 0
        for id in ids { b |= id.bit }
        bits = b
    }

    @inlinable public func contains(_ id: CajuComponentID) -> Bool { id.isValid && bits & id.bit != 0 }
    @inlinable public func isSuperset(of other: Self) -> Bool { other.bits & ~bits == 0 }
    @inlinable public func intersects(_ other: Self) -> Bool { bits & other.bits != 0 }
    @inlinable public func union(_ other: Self) -> Self { Self(bits: bits | other.bits) }
}

/// Erros do mundo ECS.
public enum CajuWorldError: Error, Equatable, Sendable {
    case invalidComponentID(CajuComponentID)
    /// Dois tipos diferentes usam o mesmo `componentID` no mesmo mundo.
    case componentIDConflict(CajuComponentID)
    case duplicateComponent(CajuComponentID)
    case staleEntity(CajuEntity)
    case missingComponent(CajuComponentID)
    /// Mudança estrutural (spawn/despawn/insert/remove) durante uma consulta; use `CajuCommandBuffer`.
    case structuralChangeDuringIteration
    case capacityExceeded
}

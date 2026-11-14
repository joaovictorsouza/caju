/// Máquina de estados com transição adiada: `request` no quadro, `consumeTransition` no ponto de sync.
public struct CajuStateMachine<S: Equatable & Sendable>: Sendable {
    public private(set) var current: S
    public private(set) var pending: S?

    public init(initial: S) { current = initial }

    /// Pede a transição (a última chamada do quadro vence). Pedir o estado atual cancela o pedido.
    public mutating func request(_ next: S) { pending = (next == current) ? nil : next }

    /// Aplica a transição pedida, se houver, e devolve `(from, to)` para os ganchos de saída/entrada.
    public mutating func consumeTransition() -> (from: S, to: S)? {
        guard let next = pending else { return nil }
        let from = current
        current = next
        pending = nil
        return (from, next)
    }
}

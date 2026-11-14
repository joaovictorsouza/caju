/// Tempo do quadro entregue aos sistemas. Fonte injetada (relógio manual em testes; sem relógio de parede).
public struct CajuTime: Sendable, Equatable {
    /// Duração do passo atual em segundos (fixo dentro de `.fixedUpdate`).
    public var delta: Double
    /// Tempo acumulado em segundos.
    public var elapsed: Double
    /// Índice do quadro (começa em 0).
    public var frame: UInt64

    public init(delta: Double = 0, elapsed: Double = 0, frame: UInt64 = 0) {
        self.delta = delta
        self.elapsed = elapsed
        self.frame = frame
    }
}

/// Acumulador de passo fixo com limite de recuperação (evita a "espiral da morte").
public struct CajuFixedTimestep: Sendable, Equatable {
    public let step: Double
    public let maxSteps: Int
    public private(set) var accumulator: Double = 0

    /// `step` ≤ 0 ou não finito vira 1/60; `maxSteps` < 1 vira 1.
    public init(step: Double = 1.0 / 60.0, maxSteps: Int = 8) {
        self.step = (step > 0 && step.isFinite) ? step : 1.0 / 60.0
        self.maxSteps = max(1, maxSteps)
    }

    /// Soma `delta` (ignora negativo/NaN) e devolve quantos passos rodar. Excesso além de
    /// `maxSteps` é descartado.
    public mutating func advance(by delta: Double) -> Int {
        if delta > 0 && delta.isFinite { accumulator += delta }
        var steps = 0
        while accumulator >= step && steps < maxSteps {
            accumulator -= step
            steps += 1
        }
        if steps == maxSteps && accumulator >= step { accumulator = 0 }
        return steps
    }

    /// Fração do próximo passo já acumulada, em 0..<1 (para interpolação).
    public var alpha: Double { accumulator / step }
}

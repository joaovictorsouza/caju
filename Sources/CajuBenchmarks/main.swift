// Harness de benchmark do Caju (M0). Saída em JSON no stdout para versionar e comparar no CI.
// Uso: swift run -c release caju-bench
import CajuMath

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#elseif canImport(Musl)
    import Musl
#endif

struct Result {
    let name: String
    let iterations: Int
    let nanosecondsPerOp: Double
}

/// Mede `body` por `iterations` repetições, após uma rodada de aquecimento.
/// Devolve a menor de 5 amostras (menos ruído).
func measure(_ name: String, iterations: Int, _ body: (Int) -> Float) -> Result {
    var sink: Float = 0
    for i in 0..<(iterations / 10) { sink += body(i) }
    var best = Double.infinity
    let clock = ContinuousClock()
    for _ in 0..<5 {
        let elapsed = clock.measure {
            for i in 0..<iterations { sink += body(i) }
        }
        let ns = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
        best = min(best, ns / Double(iterations))
    }
    // Impede que o otimizador remova o laço.
    if sink == 12345.678 { print("") }
    return Result(name: name, iterations: iterations, nanosecondsPerOp: best)
}

let q = CajuQuat(axis: CajuVec3(1, 2, 3), radians: 0.7) ?? .identity
let m = CajuMat4.rotation(q) * CajuMat4.translation(CajuVec3(1, 2, 3))
let n = 1_000_000

let results = [
    measure("vec3.cross", iterations: n) { i in
        let a = CajuVec3(Float(i & 7), 1, 2)
        return a.cross(CajuVec3(3, Float(i & 3), 1)).x
    },
    measure("quat.rotate", iterations: n) { i in
        q.rotate(CajuVec3(Float(i & 7), 1, 2)).y
    },
    measure("mat4.mul", iterations: n) { i in
        (m * CajuMat4.translation(CajuVec3(Float(i & 7), 0, 0))).c3.x
    },
]

print("{\"suite\":\"CajuMath\",\"results\":[")
for (i, r) in results.enumerated() {
    let comma = i == results.count - 1 ? "" : ","
    print(
        "  {\"name\":\"\(r.name)\",\"iterations\":\(r.iterations),\"ns_per_op\":\(r.nanosecondsPerOp)}\(comma)"
    )
}
print("]}")

// Harness de benchmark do Caju (M0). Saída em JSON no stdout para versionar e comparar no CI.
// Uso: swift run -c release caju-bench
import CajuCore
import CajuMath

#if canImport(Glibc)
    import Glibc
#elseif canImport(Android)
    import Android
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

let mathResults = [
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

// MARK: ECS (NFR-008: ≥ 100 000 entidades × 3 componentes por consulta em < 2 ms no aparelho alto (?))

struct BPos: CajuComponent {
    static let componentID = CajuComponentID(20)
    var x: Float, y: Float, z: Float
}
struct BVel: CajuComponent {
    static let componentID = CajuComponentID(21)
    var x: Float, y: Float, z: Float
}
struct BMass: CajuComponent {
    static let componentID = CajuComponentID(22)
    var m: Float
}

/// Mede `ops` operações por passada de `body` (menor de 5 passadas, após 1 de aquecimento).
func measureBatch(_ name: String, ops: Int, _ body: () -> Float) -> Result {
    var sink = body()
    var best = Double.infinity
    let clock = ContinuousClock()
    for _ in 0..<5 {
        let elapsed = clock.measure { sink += body() }
        let ns = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
        best = min(best, ns / Double(ops))
    }
    if sink == 12345.678 { print("") }
    return Result(name: name, iterations: ops, nanosecondsPerOp: best)
}

let entities = 100_000
let world = CajuWorld()
world.reserve(entities: entities)
var ecsResults: [Result] = []
do {
    let spawnWorld = CajuWorld()
    spawnWorld.reserve(entities: 1_000_000)
    ecsResults.append(
        measureBatch("ecs.spawn(3 componentes)", ops: 1_000_000) {
            for i in 0..<1_000_000 {
                _ = try? spawnWorld.spawn(BPos(x: Float(i), y: 0, z: 0), BVel(x: 1, y: 1, z: 1), BMass(m: 1))
            }
            return Float(spawnWorld.entityCount)
        })
    for i in 0..<entities {
        _ = try? world.spawn(BPos(x: Float(i), y: 0, z: 0), BVel(x: 1, y: 1, z: 1), BMass(m: 1))
    }
    ecsResults.append(
        measureBatch("ecs.query.arity3(100k)", ops: entities) {
            var acc: Float = 0
            world.forEach(CajuWrite<BPos>.self, CajuRead<BVel>.self, CajuRead<BMass>.self) { p, v, m in
                p.value.x += v.x * m.m * 0.016
                acc += p.value.x
            }
            return acc
        })
    ecsResults.append(
        measureBatch("ecs.query.pack3(100k)", ops: entities) {
            var acc: Float = 0
            world.forEachPack(CajuWrite<BPos>.self, CajuRead<BVel>.self, CajuRead<BMass>.self) { p, v, m in
                p.value.x += v.x * m.m * 0.016
                acc += p.value.x
            }
            return acc
        })
}

func emit(_ suite: String, _ results: [Result], last: Bool) {
    print("{\"suite\":\"\(suite)\",\"results\":[")
    for (i, r) in results.enumerated() {
        let comma = i == results.count - 1 ? "" : ","
        print(
            "  {\"name\":\"\(r.name)\",\"iterations\":\(r.iterations),\"ns_per_op\":\(r.nanosecondsPerOp)}\(comma)"
        )
    }
    print("]}")
}
emit("CajuMath", mathResults, last: false)
emit("CajuCore", ecsResults, last: true)

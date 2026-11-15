import Observation

@Observable
final class GameState {
    var score: Int = 0
    var lives: Int = 3
    var unobservedField: String = "idle"
}

func testObservationTracking() -> Bool {
    let state = GameState()
    nonisolated(unsafe) var changeCount = 0
    
    withObservationTracking {
        _ = state.score
    } onChange: {
        changeCount += 1
    }
    
    guard changeCount == 0 else {
        print("FAIL: onChange fired before mutation")
        return false
    }
    
    // Mutating unobserved field should NOT trigger onChange
    state.unobservedField = "running"
    guard changeCount == 0 else {
        print("FAIL: onChange fired for untracked property")
        return false
    }
    
    // Mutating observed property MUST trigger onChange
    state.score = 10
    guard changeCount == 1 else {
        print("FAIL: onChange did not fire for tracked property (count = \(changeCount))")
        return false
    }
    
    // In Observation, onChange triggers only once per registration
    state.score = 20
    guard changeCount == 1 else {
        print("FAIL: onChange fired more than once for single registration (count = \(changeCount))")
        return false
    }
    
    print("OK: withObservationTracking correctly tracked mutation and fired onChange once")
    return true
}

@main
struct Main {
    static func main() {
        print("=== Teste do Observation Framework no Android arm64 ===")
        if testObservationTracking() {
            print("Resultado: OK")
        } else {
            print("Resultado: FAIL")
        }
    }
}

// Fora do Android: no build cruzado (swift-android-action, com índice ligado) o SwiftPM falha ao abrir
// o índice do código expandido da macro ("Failed opening .../index/store/...CajuComponentMacroTests...").
// O CajuCore em si compila; só o uso da macro neste teste é pulado até o job Android estabilizar (ADR 0020).
#if !os(Android)
    import CajuCore
    import Testing

    @Component(id: 50)
    private struct MacroPos { var x: Float }

    @Component(id: 51)
    private struct MacroVel { var x: Float }

    @Suite("@Component")
    struct CajuComponentMacroTests {
        @Test func generatesStaticComponentID() {
            #expect(MacroPos.componentID == CajuComponentID(50))
            #expect(MacroVel.componentID == CajuComponentID(51))
        }

        @Test func worksWithWorldAndQuery() throws {
            let world = CajuWorld()
            _ = try world.spawn(MacroPos(x: 1), MacroVel(x: 2))
            var sum: Float = 0
            world.forEach(CajuRead<MacroPos>.self, CajuRead<MacroVel>.self) { p, v in sum += p.x + v.x }
            #expect(sum == 3)
        }
    }
#endif

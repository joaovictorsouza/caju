import Testing

@testable import CajuMath

@Suite("BitwiseCopyable")
struct CajuBitwiseCopyableTests {
    /// Falha de compilação se algum tipo POD deixar de ser `BitwiseCopyable`.
    private func exige<T: BitwiseCopyable>(_ tipo: T.Type) -> Bool { true }

    @Test("tipos POD do CajuMath são BitwiseCopyable")
    func tiposPOD() {
        #expect(exige(CajuVec2.self))
        #expect(exige(CajuVec3.self))
        #expect(exige(CajuVec4.self))
        #expect(exige(CajuQuat.self))
        #expect(exige(CajuMat4.self))
        #expect(exige(CajuColor.self))
        #expect(exige(CajuRay.self))
        #expect(exige(CajuAABB.self))
        #expect(exige(CajuSphere.self))
        #expect(exige(CajuPlane.self))
        #expect(exige(CajuFrustum.self))
    }
}

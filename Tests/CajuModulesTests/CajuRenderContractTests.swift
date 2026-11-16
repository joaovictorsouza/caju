import CajuRender
import Testing

@Suite("CajuRender: contrato R-1 (chave de draw list)")
struct CajuRenderContractTests {
    @Test func queueOrdersBeforePipelineAndMaterial() {
        let shadow = CajuDrawKey(queue: .shadow, pipeline: 9, material: 9, depth: 1)
        let opaque = CajuDrawKey(queue: .opaque, pipeline: 0, material: 0, depth: 0)
        let blend = CajuDrawKey(queue: .blend, pipeline: 0, material: 0, depth: 0)
        #expect(shadow < opaque)
        #expect(opaque < blend)
    }

    @Test func opaqueFrontToBackAndBlendBackToFront() {
        let near = CajuDrawKey(queue: .opaque, pipeline: 1, material: 1, depth: 1)
        let far = CajuDrawKey(queue: .opaque, pipeline: 1, material: 1, depth: 50)
        #expect(near < far)
        let blendNear = CajuDrawKey(queue: .blend, pipeline: 1, material: 1, depth: 1)
        let blendFar = CajuDrawKey(queue: .blend, pipeline: 1, material: 1, depth: 50)
        #expect(blendFar < blendNear)
    }

    @Test func fieldsSaturateWithoutBleeding() {
        let key = CajuDrawKey(queue: .opaque, pipeline: .max, material: .max, depth: -3)
        #expect(key.queue == CajuRenderQueue.opaque.rawValue)
        #expect(key.pipeline == 0xFFF)
        #expect(key.material == 0xFFFF)
        #expect(key.bits & 0xFFFF_FFFF == 0)
    }

    @Test func nanDepthIsZero() {
        let key = CajuDrawKey(queue: .opaque, pipeline: 0, material: 0, depth: .nan)
        #expect(key.bits & 0xFFFF_FFFF == 0)
    }

    @Test func drawItemHasNoPoseByDefault() {
        let item = CajuDrawItem(
            key: CajuDrawKey(bits: 0), mesh: .null, material: .null, instanceIndex: 0)
        #expect(item.poseIndex == CajuDrawItem.noPose)
    }
}

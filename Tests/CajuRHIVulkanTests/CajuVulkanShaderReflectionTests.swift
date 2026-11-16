import Testing

@testable import CajuRHIVulkan

@Suite("CajuVulkanShaderReflection")
struct CajuVulkanShaderReflectionTests {
    typealias Reflection = CajuVulkanShaderReflection

    /// SPIR-V de `Fixtures/reflection.frag` (`glslc -mfmt=num`, shaderc v2026.2).
    static let fragment: [UInt32] = [
        0x0723_0203, 0x0001_0000, 0x000d_000b, 0x0000_002d, 0x0000_0000, 0x0002_0011, 0x0000_0001,
        0x0006_000b, 0x0000_0001, 0x4c53_4c47, 0x6474_732e, 0x3035_342e, 0x0000_0000, 0x0003_000e,
        0x0000_0000, 0x0000_0001, 0x0006_000f, 0x0000_0004, 0x0000_0004, 0x6e69_616d, 0x0000_0000,
        0x0000_0009, 0x0003_0010, 0x0000_0004, 0x0000_0007, 0x0003_0003, 0x0000_0002, 0x0000_01c2,
        0x000a_0004, 0x475f_4c47, 0x4c47_4f4f, 0x7063_5f45, 0x7473_5f70, 0x5f65_6c79, 0x656e_696c,
        0x7269_645f, 0x6974_6365, 0x0000_6576, 0x0008_0004, 0x475f_4c47, 0x4c47_4f4f, 0x6e69_5f45,
        0x6475_6c63, 0x6964_5f65, 0x7463_6572, 0x0065_7669, 0x0004_0005, 0x0000_0004, 0x6e69_616d,
        0x0000_0000, 0x0005_0005, 0x0000_0009, 0x4374_756f, 0x726f_6c6f, 0x0000_0000, 0x0004_0005,
        0x0000_000a, 0x6172_6150, 0x0000_736d, 0x0005_0006, 0x0000_000a, 0x0000_0000, 0x746e_6974,
        0x0000_0000, 0x0004_0005, 0x0000_000c, 0x6172_6170, 0x0000_736d, 0x0004_0005, 0x0000_0014,
        0x6562_6c61, 0x0000_6f64, 0x0006_0005, 0x0000_0018, 0x6562_6c61, 0x6153_6f64, 0x656c_706d,
        0x0000_0072, 0x0005_0005, 0x0000_0022, 0x626d_6f63, 0x6465_6e69, 0x0000_0000, 0x0004_0005,
        0x0000_0027, 0x6174_6144, 0x0000_0000, 0x0005_0006, 0x0000_0027, 0x0000_0000, 0x756c_6176,
        0x0000_7365, 0x0004_0005, 0x0000_0029, 0x6174_6164, 0x0000_0000, 0x0004_0047, 0x0000_0009,
        0x0000_001e, 0x0000_0000, 0x0003_0047, 0x0000_000a, 0x0000_0002, 0x0005_0048, 0x0000_000a,
        0x0000_0000, 0x0000_0023, 0x0000_0000, 0x0004_0047, 0x0000_000c, 0x0000_0021, 0x0000_0010,
        0x0004_0047, 0x0000_000c, 0x0000_0022, 0x0000_0000, 0x0004_0047, 0x0000_0014, 0x0000_0021,
        0x0000_0030, 0x0004_0047, 0x0000_0014, 0x0000_0022, 0x0000_0000, 0x0004_0047, 0x0000_0018,
        0x0000_0021, 0x0000_0050, 0x0004_0047, 0x0000_0018, 0x0000_0022, 0x0000_0000, 0x0004_0047,
        0x0000_0022, 0x0000_0021, 0x0000_0031, 0x0004_0047, 0x0000_0022, 0x0000_0022, 0x0000_0000,
        0x0004_0047, 0x0000_0026, 0x0000_0006, 0x0000_0010, 0x0003_0047, 0x0000_0027, 0x0000_0003,
        0x0004_0048, 0x0000_0027, 0x0000_0000, 0x0000_0018, 0x0005_0048, 0x0000_0027, 0x0000_0000,
        0x0000_0023, 0x0000_0000, 0x0003_0047, 0x0000_0029, 0x0000_0018, 0x0004_0047, 0x0000_0029,
        0x0000_0021, 0x0000_0011, 0x0004_0047, 0x0000_0029, 0x0000_0022, 0x0000_0000, 0x0002_0013,
        0x0000_0002, 0x0003_0021, 0x0000_0003, 0x0000_0002, 0x0003_0016, 0x0000_0006, 0x0000_0020,
        0x0004_0017, 0x0000_0007, 0x0000_0006, 0x0000_0004, 0x0004_0020, 0x0000_0008, 0x0000_0003,
        0x0000_0007, 0x0004_003b, 0x0000_0008, 0x0000_0009, 0x0000_0003, 0x0003_001e, 0x0000_000a,
        0x0000_0007, 0x0004_0020, 0x0000_000b, 0x0000_0002, 0x0000_000a, 0x0004_003b, 0x0000_000b,
        0x0000_000c, 0x0000_0002, 0x0004_0015, 0x0000_000d, 0x0000_0020, 0x0000_0001, 0x0004_002b,
        0x0000_000d, 0x0000_000e, 0x0000_0000, 0x0004_0020, 0x0000_000f, 0x0000_0002, 0x0000_0007,
        0x0009_0019, 0x0000_0012, 0x0000_0006, 0x0000_0001, 0x0000_0000, 0x0000_0000, 0x0000_0000,
        0x0000_0001, 0x0000_0000, 0x0004_0020, 0x0000_0013, 0x0000_0000, 0x0000_0012, 0x0004_003b,
        0x0000_0013, 0x0000_0014, 0x0000_0000, 0x0002_001a, 0x0000_0016, 0x0004_0020, 0x0000_0017,
        0x0000_0000, 0x0000_0016, 0x0004_003b, 0x0000_0017, 0x0000_0018, 0x0000_0000, 0x0003_001b,
        0x0000_001a, 0x0000_0012, 0x0004_0017, 0x0000_001c, 0x0000_0006, 0x0000_0002, 0x0004_002b,
        0x0000_0006, 0x0000_001d, 0x3f00_0000, 0x0005_002c, 0x0000_001c, 0x0000_001e, 0x0000_001d,
        0x0000_001d, 0x0004_0020, 0x0000_0021, 0x0000_0000, 0x0000_001a, 0x0004_003b, 0x0000_0021,
        0x0000_0022, 0x0000_0000, 0x0003_001d, 0x0000_0026, 0x0000_0007, 0x0003_001e, 0x0000_0027,
        0x0000_0026, 0x0004_0020, 0x0000_0028, 0x0000_0002, 0x0000_0027, 0x0004_003b, 0x0000_0028,
        0x0000_0029, 0x0000_0002, 0x0005_0036, 0x0000_0002, 0x0000_0004, 0x0000_0000, 0x0000_0003,
        0x0002_00f8, 0x0000_0005, 0x0005_0041, 0x0000_000f, 0x0000_0010, 0x0000_000c, 0x0000_000e,
        0x0004_003d, 0x0000_0007, 0x0000_0011, 0x0000_0010, 0x0004_003d, 0x0000_0012, 0x0000_0015,
        0x0000_0014, 0x0004_003d, 0x0000_0016, 0x0000_0019, 0x0000_0018, 0x0005_0056, 0x0000_001a,
        0x0000_001b, 0x0000_0015, 0x0000_0019, 0x0005_0057, 0x0000_0007, 0x0000_001f, 0x0000_001b,
        0x0000_001e, 0x0005_0085, 0x0000_0007, 0x0000_0020, 0x0000_0011, 0x0000_001f, 0x0004_003d,
        0x0000_001a, 0x0000_0023, 0x0000_0022, 0x0005_0057, 0x0000_0007, 0x0000_0024, 0x0000_0023,
        0x0000_001e, 0x0005_0081, 0x0000_0007, 0x0000_0025, 0x0000_0020, 0x0000_0024, 0x0006_0041,
        0x0000_000f, 0x0000_002a, 0x0000_0029, 0x0000_000e, 0x0000_000e, 0x0004_003d, 0x0000_0007,
        0x0000_002b, 0x0000_002a, 0x0005_0081, 0x0000_0007, 0x0000_002c, 0x0000_0025, 0x0000_002b,
        0x0003_003e, 0x0000_0009, 0x0000_002c, 0x0001_00fd, 0x0001_0038,
    ]

    @Test func readsBindingsAndKindsFromGLSL() throws {
        let bindings = try Self.fragment.withUnsafeBufferPointer { try Reflection.bindings($0) }
        #expect(
            bindings == [
                .init(set: 0, binding: 16, kind: .uniformBuffer),
                .init(set: 0, binding: 17, kind: .storageBuffer),
                .init(set: 0, binding: 48, kind: .sampledImage),
                .init(set: 0, binding: 49, kind: .combinedImageSampler),
                .init(set: 0, binding: 80, kind: .sampler),
            ])
    }

    @Test func rejectsNonSPIRVAndTruncatedInput() {
        #expect(throws: Reflection.ReflectionError.notSPIRV) {
            try [UInt32](repeating: 0, count: 8).withUnsafeBufferPointer { try Reflection.bindings($0) }
        }
        let truncated = Array(Self.fragment.prefix(12))
        #expect(throws: Reflection.ReflectionError.truncated) {
            try truncated.withUnsafeBufferPointer { try Reflection.bindings($0) }
        }
    }

    /// Fuzz simples: palavras aleatórias depois do cabeçalho nunca travam nem leem fora do buffer.
    @Test func randomWordsNeverCrash() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<2000 {
            var words: [UInt32] = [0x0723_0203, 0x0001_0000, 0, 64, 0]
            for _ in 0..<(Int(state % 40)) {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                words.append(UInt32(truncatingIfNeeded: state >> 29))
            }
            _ = try? words.withUnsafeBufferPointer { try Reflection.bindings($0) }
        }
    }

    @Test func bindingMapFollowsADR0024Ranges() {
        typealias Map = CajuVulkanBindingMap
        #expect(Map.binding(.buffer, index: 0, fragment: false) == 0)
        #expect(Map.binding(.buffer, index: 0, fragment: true) == 16)
        #expect(Map.binding(.texture, index: 3, fragment: false) == 35)
        #expect(Map.binding(.texture, index: 15, fragment: true) == 63)
        #expect(Map.binding(.sampler, index: 0, fragment: true) == 80)
        #expect(Map.binding(.buffer, index: 16, fragment: false) == nil)
        #expect(Map.binding(.sampler, index: -1, fragment: false) == nil)
        #expect(Map.samplerPairedWithTexture(binding: 49) == 81)
        #expect(Map.samplerPairedWithTexture(binding: 10) == nil)
    }
}

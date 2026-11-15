import CajuAssetsCore
import CajuTesting
import Testing

@Suite("meshopt")
struct MeshoptTests {
    // MARK: - Helpers de construção sintética

    private static func makeU16LEBytes(_ values: [UInt16]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(values.count * 2)
        for v in values {
            out.append(UInt8(truncatingIfNeeded: v))
            out.append(UInt8(truncatingIfNeeded: v >> 8))
        }
        return out
    }

    private static func makeU32LEBytes(_ values: [UInt32]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(values.count * 4)
        for v in values {
            out.append(UInt8(truncatingIfNeeded: v))
            out.append(UInt8(truncatingIfNeeded: v >> 8))
            out.append(UInt8(truncatingIfNeeded: v >> 16))
            out.append(UInt8(truncatingIfNeeded: v >> 24))
        }
        return out
    }

    private static func makePVBytes(
        _ vertices: [(UInt16, UInt16, UInt16, UInt8, UInt8, UInt16, UInt16)]
    ) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(vertices.count * 12)
        for v in vertices {
            out.append(UInt8(truncatingIfNeeded: v.0))
            out.append(UInt8(truncatingIfNeeded: v.0 >> 8))
            out.append(UInt8(truncatingIfNeeded: v.1))
            out.append(UInt8(truncatingIfNeeded: v.1 >> 8))
            out.append(UInt8(truncatingIfNeeded: v.2))
            out.append(UInt8(truncatingIfNeeded: v.2 >> 8))
            out.append(v.3)
            out.append(v.4)
            out.append(UInt8(truncatingIfNeeded: v.5))
            out.append(UInt8(truncatingIfNeeded: v.5 >> 8))
            out.append(UInt8(truncatingIfNeeded: v.6))
            out.append(UInt8(truncatingIfNeeded: v.6 >> 8))
        }
        return out
    }

    private static func makeEmptyVertexStream(version: Int, stride: Int) -> [UInt8] {
        let tailSize = stride + (version == 0 ? 0 : stride / 4)
        let tailMin = version == 0 ? 32 : 24
        let tailPad = max(tailSize, tailMin)
        var bytes = [UInt8](repeating: 0, count: 1 + tailPad)
        bytes[0] = UInt8(0xa0 | version)
        return bytes
    }

    private static func makeEmptyIndexStream(version: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 1 + 16)
        bytes[0] = UInt8(0xe0 | version)
        return bytes
    }

    private static func makeEmptySequenceStream(version: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 1 + 4)
        bytes[0] = UInt8(0xd0 | version)
        return bytes
    }

    // MARK: - Vetores de referência (meshoptimizer tests.cpp)

    private static let kIndexBuffer: [UInt32] = [0, 1, 2, 2, 1, 3, 4, 6, 5, 7, 8, 9]

    private static let kIndexDataV0: [UInt8] = [
        0xe0, 0xf0, 0x10, 0xfe, 0xff, 0xf0, 0x0c, 0xff, 0x02, 0x02, 0x02, 0x00, 0x76, 0x87, 0x56, 0x67,
        0x78, 0xa9, 0x86, 0x65, 0x89, 0x68, 0x98, 0x01, 0x69, 0x00, 0x00,
    ]

    private static let kIndexBufferTricky: [UInt32] = [0, 1, 2, 2, 1, 3, 0, 1, 2, 2, 1, 5, 2, 1, 4]

    private static let kIndexDataV1: [UInt8] = [
        0xe1, 0xf0, 0x10, 0xfe, 0x1f, 0x3d, 0x00, 0x0a, 0x00, 0x76, 0x87, 0x56, 0x67, 0x78, 0xa9, 0x86,
        0x65, 0x89, 0x68, 0x98, 0x01, 0x69, 0x00, 0x00,
    ]

    private static let kIndexSequence: [UInt32] = [0, 1, 51, 2, 49, 1000]

    private static let kIndexSequenceV1: [UInt8] = [
        0xd1, 0x00, 0x04, 0xcd, 0x01, 0x04, 0x07, 0x98, 0x1f, 0x00, 0x00, 0x00, 0x00,
    ]

    private static let kVertexBuffer: [(UInt16, UInt16, UInt16, UInt8, UInt8, UInt16, UInt16)] = [
        (0, 0, 0, 0, 0, 0, 0),
        (300, 0, 0, 0, 0, 500, 0),
        (0, 300, 0, 0, 0, 0, 500),
        (300, 300, 0, 0, 0, 500, 500),
    ]

    private static let kVertexDataV0: [UInt8] = [
        0xa0, 0x01, 0x3f, 0x00, 0x00, 0x00, 0x58, 0x57, 0x58, 0x01, 0x26, 0x00, 0x00, 0x00, 0x01, 0x0c,
        0x00, 0x00, 0x00, 0x58, 0x01, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x3f, 0x00,
        0x00, 0x00, 0x17, 0x18, 0x17, 0x01, 0x26, 0x00, 0x00, 0x00, 0x01, 0x0c, 0x00, 0x00, 0x00, 0x17,
        0x01, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00,
    ]

    private static let kVertexDataV1: [UInt8] = [
        0xa1, 0xee, 0xaa, 0xee, 0x00, 0x4b, 0x4b, 0x4b, 0x00, 0x00, 0x4b, 0x00, 0x00, 0x7d, 0x7d, 0x7d,
        0x00, 0x00, 0x7d, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x62, 0x00, 0x62,
    ]

    private static let kVertexDataV1Custom: [UInt8] = [
        0xa1, 0xd4, 0x94, 0xd4, 0x01, 0x0e, 0x00, 0x58, 0x57, 0x58, 0x02, 0x02, 0x12, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x58, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x0e, 0x00, 0x7d, 0x7d, 0x7d, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7d, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x62,
    ]

    // MARK: - Testes de decodificação de índices

    @Test func decodeIndexBufferV0AndV1() throws {
        let decodedV0 = try Meshopt.decodeIndexBuffer(
            count: Self.kIndexBuffer.count,
            indexSize: 4,
            Self.kIndexDataV0
        )
        #expect(decodedV0 == Self.makeU32LEBytes(Self.kIndexBuffer))

        let decodedV0U16 = try Meshopt.decodeIndexBuffer(
            count: Self.kIndexBuffer.count,
            indexSize: 2,
            Self.kIndexDataV0
        )
        #expect(decodedV0U16 == Self.makeU16LEBytes(Self.kIndexBuffer.map { UInt16($0) }))

        let decodedV1 = try Meshopt.decodeIndexBuffer(
            count: Self.kIndexBufferTricky.count,
            indexSize: 4,
            Self.kIndexDataV1
        )
        #expect(decodedV1 == Self.makeU32LEBytes(Self.kIndexBufferTricky))

        let inputMore: [UInt8] = [
            0xe1, 0xf0, 0x10, 0xfe, 0xff, 0xf0, 0x0c, 0xff, 0x02, 0x02, 0x02, 0x00, 0x76, 0x87, 0x56, 0x67,
            0x78, 0xa9, 0x86, 0x65, 0x89, 0x68, 0x98, 0x01, 0x69, 0x00, 0x00,
        ]
        let decodedMore = try Meshopt.decodeIndexBuffer(
            count: Self.kIndexBuffer.count,
            indexSize: 4,
            inputMore
        )
        #expect(decodedMore == Self.makeU32LEBytes(Self.kIndexBuffer))

        let inputThreeEdges: [UInt8] = [
            0xe1, 0xf0, 0x20, 0x30, 0x40, 0x00, 0x76, 0x87, 0x56, 0x67, 0x78, 0xa9, 0x86, 0x65, 0x89, 0x68,
            0x98, 0x01, 0x69, 0x00, 0x00,
        ]
        let expectedThreeEdges: [UInt32] = [0, 1, 2, 1, 0, 3, 2, 1, 4, 0, 2, 5]
        let decodedThreeEdges = try Meshopt.decodeIndexBuffer(
            count: expectedThreeEdges.count,
            indexSize: 4,
            inputThreeEdges
        )
        #expect(decodedThreeEdges == Self.makeU32LEBytes(expectedThreeEdges))
    }

    @Test func decodeIndexSequenceV1AndEmpty() throws {
        let decoded32 = try Meshopt.decodeIndexSequence(
            count: Self.kIndexSequence.count,
            indexSize: 4,
            Self.kIndexSequenceV1
        )
        #expect(decoded32 == Self.makeU32LEBytes(Self.kIndexSequence))

        let decoded16 = try Meshopt.decodeIndexSequence(
            count: Self.kIndexSequence.count,
            indexSize: 2,
            Self.kIndexSequenceV1
        )
        #expect(decoded16 == Self.makeU16LEBytes(Self.kIndexSequence.map { UInt16($0) }))

        let emptySeq = try Meshopt.decodeIndexSequence(
            count: 0,
            indexSize: 4,
            Self.makeEmptySequenceStream(version: 1)
        )
        #expect(emptySeq.isEmpty)

        let emptyIdx = try Meshopt.decodeIndexBuffer(
            count: 0,
            indexSize: 2,
            Self.makeEmptyIndexStream(version: 0)
        )
        #expect(emptyIdx.isEmpty)
    }

    // MARK: - Testes de decodificação de vértices

    @Test func decodeVertexBufferV0AndV1() throws {
        let expectedPV = Self.makePVBytes(Self.kVertexBuffer)

        let decodedV0 = try Meshopt.decodeVertexBuffer(count: 4, stride: 12, Self.kVertexDataV0)
        #expect(decodedV0 == expectedPV)

        let decodedV1 = try Meshopt.decodeVertexBuffer(count: 4, stride: 12, Self.kVertexDataV1)
        #expect(decodedV1 == expectedPV)

        let decodedV1Custom = try Meshopt.decodeVertexBuffer(count: 4, stride: 12, Self.kVertexDataV1Custom)
        #expect(decodedV1Custom == expectedPV)

        let empty = try Meshopt.decodeVertexBuffer(
            count: 0,
            stride: 16,
            Self.makeEmptyVertexStream(version: 1, stride: 16)
        )
        #expect(empty.isEmpty)
    }

    @Test func decodeVertexBufferVectorsFromTestsCpp() throws {
        let expectedV0More: [UInt8] = [
            0, 0, 0, 0, 0, 1, 2, 8, 0, 2, 4, 16, 0, 3, 6, 24,
            0, 4, 8, 32, 0, 5, 10, 40, 0, 6, 12, 48, 0, 7, 14, 56,
            0, 8, 16, 64, 0, 9, 18, 72, 0, 10, 20, 80, 0, 11, 22, 88,
            0, 12, 24, 96, 0, 13, 26, 104, 0, 14, 28, 112, 0, 15, 30, 120,
        ]
        let inputV0More: [UInt8] = [
            0xa0, 0x00, 0x01, 0x2a, 0xaa, 0xaa, 0xaa, 0x02, 0x04, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44,
            0x03, 0x00, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
            0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00,
        ]
        #expect(try Meshopt.decodeVertexBuffer(count: 16, stride: 4, inputV0More) == expectedV0More)

        let expectedV0Mode2: [UInt8] = [
            0, 0, 0, 0, 4, 5, 6, 7, 8, 10, 12, 14, 12, 15, 18, 21,
            16, 20, 24, 28, 20, 25, 30, 35, 24, 30, 36, 42, 28, 35, 42, 49,
            32, 40, 48, 56, 36, 45, 54, 63, 40, 50, 60, 70, 44, 55, 66, 77,
            48, 60, 72, 84, 52, 65, 78, 91, 56, 70, 84, 98, 60, 75, 90, 105,
        ]
        let inputV0Mode2: [UInt8] = [
            0xa0, 0x02, 0x08, 0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x02, 0x0a, 0xaa, 0xaa, 0xaa, 0xaa,
            0xaa, 0xaa, 0xaa, 0x02, 0x0c, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0x02, 0x0e, 0xee, 0xee,
            0xee, 0xee, 0xee, 0xee, 0xee, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        #expect(try Meshopt.decodeVertexBuffer(count: 16, stride: 4, inputV0Mode2) == expectedV0Mode2)

        let expectedV1Deltas: [UInt16] = [
            248, 248, 240, 240, 249, 250, 243, 244, 250, 252, 246, 248, 251, 254, 249, 252,
            252, 256, 252, 256, 253, 258, 255, 260, 254, 260, 258, 264, 255, 262, 261, 268,
            256, 264, 264, 272, 257, 262, 267, 268, 258, 260, 270, 264, 259, 258, 273, 260,
            260, 256, 276, 256, 261, 254, 279, 252, 262, 252, 282, 248, 263, 250, 285, 244,
        ]
        let inputV1Deltas: [UInt8] = [
            0xa1, 0x99, 0x99, 0x01, 0x2a, 0xaa, 0xaa, 0xaa, 0x02, 0x04, 0x44, 0x44, 0x44, 0x43, 0x33, 0x33,
            0x33, 0x02, 0x06, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x02, 0x08, 0x88, 0x88, 0x88, 0x87,
            0x77, 0x77, 0x77, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0xf8, 0x00, 0xf8, 0x00, 0xf0, 0x00, 0xf0, 0x00, 0x01, 0x01,
        ]
        #expect(
            try Meshopt.decodeVertexBuffer(count: 16, stride: 8, inputV1Deltas)
                == Self.makeU16LEBytes(expectedV1Deltas)
        )

        let expectedSentinels: [UInt8] = [
            0xff, 0, 0, 0, 0xfe, 0, 0, 0, 0xfd, 0, 0, 0, 0xfd, 0, 0, 0,
            0xfd, 0, 0, 0, 0xfc, 0, 0, 0, 0xfb, 0, 0, 0, 0xfb, 0, 0, 0,
            0xfa, 0, 0, 0, 0xfa, 0, 0, 0, 0xf9, 0, 0, 0, 0xf9, 0, 0, 0,
            0xf8, 0, 0, 0,
        ]
        let inputSentinels: [UInt8] = [
            0xa1, 0xa9,
            0x01, 0xfc, 0x3c, 0xcc, 0xcc,
            0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ]
        #expect(try Meshopt.decodeVertexBuffer(count: 13, stride: 4, inputSentinels) == expectedSentinels)
    }

    // MARK: - Testes de filtros

    @Test func applyFilterOctahedral8And16() throws {
        let data8: [UInt8] = [
            0, 1, 127, 0,
            0, 187, 127, 1,
            255, 1, 127, 0,
            14, 130, 127, 1,
        ]
        let expected8: [UInt8] = [
            0, 1, 127, 0,
            0, 159, 82, 1,
            255, 1, 127, 0,
            1, 130, 241, 1,
        ]

        var full8 = data8
        try Meshopt.applyFilter(.octahedral, count: 4, stride: 4, to: &full8)
        #expect(full8 == expected8)

        var tail8 = Array(data8[0..<(3 * 4)])
        try Meshopt.applyFilter(.octahedral, count: 3, stride: 4, to: &tail8)
        #expect(tail8 == Array(expected8[0..<(3 * 4)]))

        let data16: [UInt16] = [
            0, 1, 2047, 0,
            0, 1870, 2047, 1,
            2017, 1, 2047, 0,
            14, 1300, 2047, 1,
        ]
        let expected16: [UInt16] = [
            0, 16, 32767, 0,
            0, 32621, 3088, 1,
            32764, 16, 471, 0,
            307, 28541, 16093, 1,
        ]

        var full16 = Self.makeU16LEBytes(data16)
        try Meshopt.applyFilter(.octahedral, count: 4, stride: 8, to: &full16)
        #expect(full16 == Self.makeU16LEBytes(expected16))

        var tail16 = Self.makeU16LEBytes(Array(data16[0..<(3 * 4)]))
        try Meshopt.applyFilter(.octahedral, count: 3, stride: 8, to: &tail16)
        #expect(tail16 == Self.makeU16LEBytes(Array(expected16[0..<(3 * 4)])))
    }

    @Test func applyFilterQuaternionAndExponential() throws {
        let quatInput: [UInt16] = [
            0, 1, 0, 0x7fc,
            0, 1870, 0, 0x7fd,
            2017, 1, 0, 0x7fe,
            14, 1300, 0, 0x7ff,
        ]
        let quatExpected: [UInt16] = [
            32767, 0, 11, 0,
            0, 25013, 0, 21166,
            11, 0, 23504, 22830,
            158, 14715, 0, 29277,
        ]

        var fullQuat = Self.makeU16LEBytes(quatInput)
        try Meshopt.applyFilter(.quaternion, count: 4, stride: 8, to: &fullQuat)
        #expect(fullQuat == Self.makeU16LEBytes(quatExpected))

        var tailQuat = Self.makeU16LEBytes(Array(quatInput[0..<(3 * 4)]))
        try Meshopt.applyFilter(.quaternion, count: 3, stride: 8, to: &tailQuat)
        #expect(tailQuat == Self.makeU16LEBytes(Array(quatExpected[0..<(3 * 4)])))

        let expInput: [UInt32] = [0, 0xff00_0003, 0x02ff_fff7, 0xfe7f_ffff]
        let expExpected: [UInt32] = [0, 0x3fc0_0000, 0xc210_0000, 0x49ff_fffe]

        var fullExp = Self.makeU32LEBytes(expInput)
        try Meshopt.applyFilter(.exponential, count: 4, stride: 4, to: &fullExp)
        #expect(fullExp == Self.makeU32LEBytes(expExpected))

        var tailExp = Self.makeU32LEBytes(Array(expInput[0..<3]))
        try Meshopt.applyFilter(.exponential, count: 3, stride: 4, to: &tailExp)
        #expect(tailExp == Self.makeU32LEBytes(Array(expExpected[0..<3])))

        // Stride 8 (2 floats por vértice, caso de tests.cpp encodeFilterExpOverflow)
        let expOverflowIn: [UInt32] = [0xe97f_ffff, 0xe980_0000, 0xf17f_ffff, 0xea40_0000]
        let expOverflowOut: [UInt32] = [
            Float(0.99999988).bitPattern,
            Float(-1.0).bitPattern,
            Float(255.99997).bitPattern,
            Float(1.0).bitPattern,
        ]
        var overflowBuf = Self.makeU32LEBytes(expOverflowIn)
        try Meshopt.applyFilter(.exponential, count: 2, stride: 8, to: &overflowBuf)
        #expect(overflowBuf == Self.makeU32LEBytes(expOverflowOut))
    }

    // MARK: - Casos malformados, limites e overflow

    @Test func rejectsTruncatedAndExtraBytes() {
        for cut in 0..<Self.kIndexDataV0.count {
            #expect(throws: AssetError.self) {
                _ = try Meshopt.decodeIndexBuffer(
                    count: Self.kIndexBuffer.count,
                    indexSize: 4,
                    Array(Self.kIndexDataV0[0..<cut])
                )
            }
        }
        #expect(throws: AssetError.self) {
            _ = try Meshopt.decodeIndexBuffer(
                count: Self.kIndexBuffer.count,
                indexSize: 4,
                Self.kIndexDataV0 + [0x00]
            )
        }

        for cut in 0..<Self.kIndexSequenceV1.count {
            #expect(throws: AssetError.self) {
                _ = try Meshopt.decodeIndexSequence(
                    count: Self.kIndexSequence.count,
                    indexSize: 4,
                    Array(Self.kIndexSequenceV1[0..<cut])
                )
            }
        }
        #expect(throws: AssetError.self) {
            _ = try Meshopt.decodeIndexSequence(
                count: Self.kIndexSequence.count,
                indexSize: 4,
                Self.kIndexSequenceV1 + [0x00]
            )
        }

        for cut in 0..<Self.kVertexDataV1.count {
            #expect(throws: AssetError.self) {
                _ = try Meshopt.decodeVertexBuffer(
                    count: 4,
                    stride: 12,
                    Array(Self.kVertexDataV1[0..<cut])
                )
            }
        }
        #expect(throws: AssetError.self) {
            _ = try Meshopt.decodeVertexBuffer(
                count: 4,
                stride: 12,
                Self.kVertexDataV1 + [0x00]
            )
        }
    }

    @Test func rejectsInvalidHeadersVersionsParametersAndOverflow() {
        // Cabeçalhos e versões inválidos
        var badIdxHeader = Self.kIndexDataV1
        badIdxHeader[0] = 0x00
        #expect(throws: AssetError.self) {
            _ = try Meshopt.decodeIndexBuffer(
                count: Self.kIndexBufferTricky.count,
                indexSize: 4,
                badIdxHeader
            )
        }

        var badIdxVersion = Self.kIndexDataV1
        badIdxVersion[0] = 0xe2
        #expect(throws: AssetError.self) {
            _ = try Meshopt.decodeIndexBuffer(
                count: Self.kIndexBufferTricky.count,
                indexSize: 4,
                badIdxVersion
            )
        }

        var badSeqHeader = Self.kIndexSequenceV1
        badSeqHeader[0] = 0xe1
        #expect(throws: AssetError.self) {
            _ = try Meshopt.decodeIndexSequence(count: Self.kIndexSequence.count, indexSize: 4, badSeqHeader)
        }

        var badSeqVersion = Self.kIndexSequenceV1
        badSeqVersion[0] = 0xd2
        #expect(throws: AssetError.self) {
            _ = try Meshopt.decodeIndexSequence(count: Self.kIndexSequence.count, indexSize: 4, badSeqVersion)
        }

        var badVtxHeader = Self.kVertexDataV1
        badVtxHeader[0] = 0xb1
        #expect(throws: AssetError.self) {
            _ = try Meshopt.decodeVertexBuffer(count: 4, stride: 12, badVtxHeader)
        }

        var badVtxVersion = Self.kVertexDataV1
        badVtxVersion[0] = 0xa2
        #expect(throws: AssetError.self) {
            _ = try Meshopt.decodeVertexBuffer(count: 4, stride: 12, badVtxVersion)
        }

        // Canal inválido (channel & 3 == 3) no tail v1
        var badChannel = Self.kVertexDataV1
        badChannel[badChannel.count - 1] = 0x03
        #expect(throws: AssetError.self) {
            _ = try Meshopt.decodeVertexBuffer(count: 4, stride: 12, badChannel)
        }

        // VByte malformado da referência (tests.cpp decodeIndexMalformedVByte)
        let malformedVByte: [UInt8] = [
            0xe1, 0x20, 0x20, 0x20, 0xff, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20,
            0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20,
            0xff, 0xff, 0xff, 0xff, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20,
            0x20, 0x20, 0x20,
        ]
        #expect(throws: AssetError.self) {
            _ = try Meshopt.decodeIndexBuffer(count: 66, indexSize: 4, malformedVByte)
        }

        // Parâmetros ilegais e overflow aritmético
        #expect(throws: AssetError.self) {
            _ = try Meshopt.decodeVertexBuffer(
                count: -1,
                stride: 4,
                Self.makeEmptyVertexStream(version: 1, stride: 4)
            )
        }
        #expect(throws: AssetError.self) {
            _ = try Meshopt.decodeVertexBuffer(
                count: 0,
                stride: 6,
                Self.makeEmptyVertexStream(version: 1, stride: 8)
            )
        }
        #expect(throws: AssetError.self) {
            _ = try Meshopt.decodeVertexBuffer(
                count: 0,
                stride: 260,
                Self.makeEmptyVertexStream(version: 1, stride: 4)
            )
        }
        #expect(throws: AssetError.self) {
            _ = try Meshopt.decodeVertexBuffer(count: Int.max, stride: 256, Self.kVertexDataV1)
        }
        #expect(throws: AssetError.self) {
            _ = try Meshopt.decodeIndexBuffer(count: 4, indexSize: 4, Self.kIndexDataV1)
        }
        #expect(throws: AssetError.self) {
            _ = try Meshopt.decodeIndexBuffer(count: 3, indexSize: 3, Self.kIndexDataV1)
        }
        #expect(throws: AssetError.self) {
            _ = try Meshopt.decodeIndexBuffer(count: (Int.max / 4) * 3, indexSize: 4, Self.kIndexDataV1)
        }
        #expect(throws: AssetError.self) {
            _ = try Meshopt.decodeIndexSequence(count: Int.max, indexSize: 4, Self.kIndexSequenceV1)
        }

        // Limites de entrada e saída respeitados antes de alocar
        let tinyLimits = AssetLimits(maxInputBytes: 8, maxOutputBytes: 8)
        #expect(throws: AssetError.self) {
            _ = try Meshopt.decodeVertexBuffer(count: 4, stride: 12, Self.kVertexDataV1, limits: tinyLimits)
        }
        #expect(throws: AssetError.self) {
            _ = try Meshopt.decodeIndexBuffer(
                count: Self.kIndexBuffer.count,
                indexSize: 4,
                Self.kIndexDataV0,
                limits: tinyLimits
            )
        }
        #expect(throws: AssetError.self) {
            _ = try Meshopt.decodeIndexSequence(
                count: Self.kIndexSequence.count,
                indexSize: 4,
                Self.kIndexSequenceV1,
                limits: tinyLimits
            )
        }
    }

    @Test func rejectsOutOfRangeIndexForU16AndBadFilterArgs() {
        // Sequência v1 com índice 70000 (> 65535):
        // delta 70000 -> zigzag = 140000, + baseline bit 0 = 280000 = 0x445C0 -> vbyte: 0xc0, 0x8b, 0x11
        let seqOverflowU16: [UInt8] = [0xd1, 0xc0, 0x8b, 0x11, 0x00, 0x00, 0x00, 0x00]
        #expect(throws: AssetError.self) {
            _ = try Meshopt.decodeIndexSequence(count: 1, indexSize: 2, seqOverflowU16)
        }
        // Mesma sequência cabe em 32 bits
        #expect(
            (try? Meshopt.decodeIndexSequence(count: 1, indexSize: 4, seqOverflowU16))
                == Self.makeU32LEBytes([70000])
        )

        // Buffer de índices v1 com 1 triângulo (0, 1, 70000):
        // codeaux_table[0] = 0x00, tri = 0xfe, codeaux = 0x0f (fea=0, feb=0, fec=15)
        // delta = 70000 -> zigzag = 140000 = 0x222E0 -> vbyte: 0xe0, 0xc5, 0x08
        var idxOverflowU16: [UInt8] = [0xe1, 0xfe, 0x0f, 0xe0, 0xc5, 0x08]
        idxOverflowU16.append(contentsOf: [UInt8](repeating: 0, count: 16))
        #expect(throws: AssetError.self) {
            _ = try Meshopt.decodeIndexBuffer(count: 3, indexSize: 2, idxOverflowU16)
        }
        #expect(
            (try? Meshopt.decodeIndexBuffer(count: 3, indexSize: 4, idxOverflowU16))
                == Self.makeU32LEBytes([0, 1, 70000])
        )

        // Filtros com argumentos inválidos ou valores hostis extremos (sem crash/NaN trap)
        var buf4 = [UInt8](repeating: 0, count: 4)
        #expect(throws: AssetError.self) {
            try Meshopt.applyFilter(.octahedral, count: 1, stride: 12, to: &buf4)
        }
        #expect(throws: AssetError.self) {
            try Meshopt.applyFilter(.quaternion, count: 1, stride: 4, to: &buf4)
        }
        #expect(throws: AssetError.self) {
            try Meshopt.applyFilter(.exponential, count: 1, stride: 6, to: &buf4)
        }
        #expect(throws: AssetError.self) {
            try Meshopt.applyFilter(.octahedral, count: 2, stride: 4, to: &buf4)
        }

        // Entrada toda zero no filtro octaedral (l == 0) não deve gerar NaN trap
        var zeroOct = [UInt8](repeating: 0, count: 8)
        #expect(throws: Never.self) {
            try Meshopt.applyFilter(.octahedral, count: 2, stride: 4, to: &zeroOct)
        }
    }

    // MARK: - Fuzz determinístico

    @Test func fuzzVertexDecoderNeverCrashes() {
        let fuzzLimits = AssetLimits(maxInputBytes: 2048, maxOutputBytes: 4096)
        let seeds: [(count: Int, stride: Int, data: [UInt8])] = [
            (4, 12, Self.kVertexDataV0),
            (4, 12, Self.kVertexDataV1),
            (4, 12, Self.kVertexDataV1Custom),
        ]
        let validStrides = [4, 8, 12, 16, 32, 64]

        CajuFuzz.run(seed: 0x5645_5254, iterations: 2000) { rng, i in
            let len = Int(rng.nextUInt32() % 256)
            var input = [UInt8](repeating: 0, count: len)
            for idx in 0..<len {
                input[idx] = UInt8(truncatingIfNeeded: rng.nextUInt32())
            }
            if !input.isEmpty && i % 2 == 0 {
                input[0] = UInt8(0xa0 | (i % 2))
            }
            let stride = validStrides[Int(rng.nextUInt32()) % validStrides.count]
            let count = Int(rng.nextUInt32() % 128)
            do {
                _ = try Meshopt.decodeVertexBuffer(count: count, stride: stride, input, limits: fuzzLimits)
            } catch {
                _ = error
            }
        }

        CajuFuzz.run(seed: 0x564D_5554, iterations: 2000) { rng, i in
            let seed = seeds[i % seeds.count]
            var mutated = seed.data
            let op = rng.nextUInt32() % 3
            if op == 0, !mutated.isEmpty {
                let cut = Int(rng.nextUInt32()) % mutated.count
                mutated = Array(mutated[0..<cut])
            } else if !mutated.isEmpty {
                let flips = 1 + Int(rng.nextUInt32() % 4)
                for _ in 0..<flips {
                    let pos = Int(rng.nextUInt32()) % mutated.count
                    mutated[pos] ^= UInt8(truncatingIfNeeded: (rng.nextUInt32() & 0xFF) | 1)
                }
            }
            do {
                _ = try Meshopt.decodeVertexBuffer(
                    count: seed.count,
                    stride: seed.stride,
                    mutated,
                    limits: fuzzLimits
                )
            } catch {
                _ = error
            }
        }
    }

    @Test func fuzzIndexAndSequenceDecodersNeverCrash() {
        let fuzzLimits = AssetLimits(maxInputBytes: 2048, maxOutputBytes: 4096)
        let indexSeeds: [(count: Int, data: [UInt8])] = [
            (Self.kIndexBuffer.count, Self.kIndexDataV0),
            (Self.kIndexBufferTricky.count, Self.kIndexDataV1),
        ]

        CajuFuzz.run(seed: 0x494E_4458, iterations: 2000) { rng, i in
            let len = Int(rng.nextUInt32() % 256)
            var input = [UInt8](repeating: 0, count: len)
            for idx in 0..<len {
                input[idx] = UInt8(truncatingIfNeeded: rng.nextUInt32())
            }
            let indexSize = (i % 2 == 0) ? 2 : 4
            if !input.isEmpty && i % 3 != 0 {
                input[0] = UInt8((i % 2 == 0 ? 0xe0 : 0xd0) | (i % 2))
            }
            let triCount = Int(rng.nextUInt32() % 64)
            do {
                _ = try Meshopt.decodeIndexBuffer(
                    count: triCount * 3,
                    indexSize: indexSize,
                    input,
                    limits: fuzzLimits
                )
            } catch {
                _ = error
            }
            do {
                _ = try Meshopt.decodeIndexSequence(
                    count: Int(rng.nextUInt32() % 128),
                    indexSize: indexSize,
                    input,
                    limits: fuzzLimits
                )
            } catch {
                _ = error
            }
        }

        CajuFuzz.run(seed: 0x494D_5554, iterations: 2000) { rng, i in
            let indexSize = (i % 2 == 0) ? 2 : 4
            if i % 2 == 0 {
                let seed = indexSeeds[i % indexSeeds.count]
                var mutated = seed.data
                let op = rng.nextUInt32() % 3
                if op == 0, !mutated.isEmpty {
                    let cut = Int(rng.nextUInt32()) % mutated.count
                    mutated = Array(mutated[0..<cut])
                } else if !mutated.isEmpty {
                    let flips = 1 + Int(rng.nextUInt32() % 4)
                    for _ in 0..<flips {
                        let pos = Int(rng.nextUInt32()) % mutated.count
                        mutated[pos] ^= UInt8(truncatingIfNeeded: (rng.nextUInt32() & 0xFF) | 1)
                    }
                }
                do {
                    _ = try Meshopt.decodeIndexBuffer(
                        count: seed.count,
                        indexSize: indexSize,
                        mutated,
                        limits: fuzzLimits
                    )
                } catch {
                    _ = error
                }
            } else {
                var mutated = Self.kIndexSequenceV1
                let op = rng.nextUInt32() % 3
                if op == 0, !mutated.isEmpty {
                    let cut = Int(rng.nextUInt32()) % mutated.count
                    mutated = Array(mutated[0..<cut])
                } else if !mutated.isEmpty {
                    let flips = 1 + Int(rng.nextUInt32() % 4)
                    for _ in 0..<flips {
                        let pos = Int(rng.nextUInt32()) % mutated.count
                        mutated[pos] ^= UInt8(truncatingIfNeeded: (rng.nextUInt32() & 0xFF) | 1)
                    }
                }
                do {
                    _ = try Meshopt.decodeIndexSequence(
                        count: Self.kIndexSequence.count,
                        indexSize: indexSize,
                        mutated,
                        limits: fuzzLimits
                    )
                } catch {
                    _ = error
                }
            }
        }
    }

    @Test func fuzzFiltersNeverCrash() {
        let filters: [(Meshopt.Filter, Int)] = [
            (.octahedral, 4),
            (.octahedral, 8),
            (.quaternion, 8),
            (.exponential, 4),
            (.exponential, 12),
        ]

        CajuFuzz.run(seed: 0x4649_4C54, iterations: 2000) { rng, i in
            let (filter, stride) = filters[i % filters.count]
            let count = Int(rng.nextUInt32() % 16)
            var buffer = [UInt8](repeating: 0, count: count * stride)
            for idx in 0..<buffer.count {
                buffer[idx] = UInt8(truncatingIfNeeded: rng.nextUInt32())
            }
            do {
                try Meshopt.applyFilter(filter, count: count, stride: stride, to: &buffer)
            } catch {
                _ = error
            }
        }
    }
}

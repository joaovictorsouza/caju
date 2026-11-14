import CajuMath
import CajuTesting
import Testing

@testable import CajuAssetsCore

@Suite("glTF")
struct GLTFTests {
    // MARK: - Helpers de construção sintética

    private static func utf8(_ string: String) -> [UInt8] {
        Array(string.utf8)
    }

    private static func appendU32LE(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func buildGLB(
        json: String,
        bin: [UInt8]? = nil,
        extraChunks: [(type: UInt32, data: [UInt8])] = []
    ) -> [UInt8] {
        var jsonBytes = utf8(json)
        while jsonBytes.count % 4 != 0 {
            jsonBytes.append(0x20)
        }

        var binBytes = bin ?? []
        while binBytes.count % 4 != 0 {
            binBytes.append(0x00)
        }

        var totalLength = 12 + 8 + jsonBytes.count
        if bin != nil {
            totalLength += 8 + binBytes.count
        }
        var paddedExtra: [(type: UInt32, data: [UInt8])] = []
        for chunk in extraChunks {
            var data = chunk.data
            while data.count % 4 != 0 {
                data.append(0x00)
            }
            totalLength += 8 + data.count
            paddedExtra.append((chunk.type, data))
        }

        var out: [UInt8] = []
        out.reserveCapacity(totalLength)
        appendU32LE(0x4654_6C67, to: &out)  // "glTF"
        appendU32LE(2, to: &out)
        appendU32LE(UInt32(totalLength), to: &out)

        appendU32LE(UInt32(jsonBytes.count), to: &out)
        appendU32LE(0x4E4F_534A, to: &out)  // "JSON"
        out.append(contentsOf: jsonBytes)

        if bin != nil {
            appendU32LE(UInt32(binBytes.count), to: &out)
            appendU32LE(0x004E_4942, to: &out)  // "BIN\0"
            out.append(contentsOf: binBytes)
        }

        for chunk in paddedExtra {
            appendU32LE(UInt32(chunk.data.count), to: &out)
            appendU32LE(chunk.type, to: &out)
            out.append(contentsOf: chunk.data)
        }

        return out
    }

    private static let minimalTriangleJSON = """
        {
          "asset": { "version": "2.0" },
          "scene": 0,
          "scenes": [{ "name": "Main", "nodes": [0] }],
          "nodes": [
            { "name": "Root", "children": [1], "translation": [1, 2, 3], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1] },
            { "name": "MeshNode", "mesh": 0, "matrix": [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1] }
          ],
          "materials": [{}],
          "textures": [{}],
          "images": [{ "uri": "albedo.png" }],
          "meshes": [
            {
              "name": "Tri",
              "primitives": [
                {
                  "attributes": { "POSITION": 0, "TEXCOORD_0": 1 },
                  "indices": 2,
                  "material": 0,
                  "mode": 4
                }
              ]
            }
          ],
          "accessors": [
            {
              "bufferView": 0,
              "byteOffset": 0,
              "componentType": 5126,
              "count": 3,
              "type": "VEC3",
              "min": [0, 0, 0],
              "max": [1, 1, 0]
            },
            {
              "bufferView": 0,
              "byteOffset": 12,
              "componentType": 5126,
              "count": 3,
              "type": "VEC2"
            },
            {
              "bufferView": 1,
              "byteOffset": 0,
              "componentType": 5123,
              "count": 3,
              "type": "SCALAR"
            }
          ],
          "bufferViews": [
            { "buffer": 0, "byteOffset": 0, "byteLength": 60, "byteStride": 20, "target": 34962 },
            { "buffer": 0, "byteOffset": 60, "byteLength": 6, "target": 34963 }
          ],
          "buffers": [
            { "byteLength": 66, "uri": "data:application/octet-stream;base64,AAAA" }
          ]
        }
        """

    // MARK: - JSON unitários

    @Test func jsonParsesValuesEscapesAndOrder() throws {
        let src = #"""
            {
              "z": null,
              "a": true,
              "b": false,
              "num": -12.5e2,
              "zero": 0,
              "esc": "\"\\\/\b\f\n\r\t\u0041\uD83D\uDE00",
              "arr": [1, 2.5, "x"]
            }
            """#
        let value = try JSONParser.parse(Self.utf8(src))
        let expected: JSONValue = .object([
            ("z", .null),
            ("a", .bool(true)),
            ("b", .bool(false)),
            ("num", .number(-1250.0)),
            ("zero", .number(0.0)),
            ("esc", .string("\"\\/\u{08}\u{0C}\n\r\tA😀")),
            ("arr", .array([.number(1.0), .number(2.5), .string("x")])),
        ])
        #expect(value == expected)
    }

    @Test func jsonRejectsInvalidInputsAndRespectsLimits() {
        let invalidInputs = [
            "{} 1",
            "[1,]",
            "{\"a\":1,}",
            "01",
            "-01",
            "+1",
            "1.",
            ".5",
            "1e",
            "1e+",
            "1e400",
            "\"\\a\"",
            "\"\\u123Z\"",
            "\"\\uD83D\"",
            "\"\\uD83D\\u0041\"",
            "\"\\uDE00\"",
            "\"linha\nquebrada\"",
        ]
        for text in invalidInputs {
            do {
                _ = try JSONParser.parse(Self.utf8(text))
                Issue.record("Esperava AssetError para JSON inválido: \(text)")
            } catch {
                // Esperado
            }
        }

        // UTF-8 inválido dentro de string (overlong e surrogate direto)
        let badUTF8Cases: [[UInt8]] = [
            [0x22, 0xC0, 0xAF, 0x22],
            [0x22, 0xED, 0xA0, 0x80, 0x22],
            [0x22, 0xF4, 0x90, 0x80, 0x80, 0x22],
            [0x22, 0xE2, 0x82, 0x22],
        ]
        for bytes in badUTF8Cases {
            do {
                _ = try JSONParser.parse(bytes)
                Issue.record("Esperava AssetError para UTF-8 inválido")
            } catch {}
        }

        // Limite de profundidade
        let deepLimits = AssetLimits(maxJSONDepth: 2)
        do {
            _ = try JSONParser.parse(Self.utf8("[[[]]]"), limits: deepLimits)
            Issue.record("Esperava limitExceeded para profundidade")
        } catch let error {
            guard case .limitExceeded = error else {
                Issue.record("Esperava .limitExceeded, veio \(error)")
                return
            }
        }

        // Limite de elementos
        let elemLimits = AssetLimits(maxElements: 2)
        do {
            _ = try JSONParser.parse(Self.utf8("[1, 2, 3]"), limits: elemLimits)
            Issue.record("Esperava limitExceeded para elementos")
        } catch let error {
            guard case .limitExceeded = error else {
                Issue.record("Esperava .limitExceeded, veio \(error)")
                return
            }
        }
    }

    @Test func jsonHandlesDeepIterativeNestingWithoutOverflow() throws {
        let depth = 512
        var bytes: [UInt8] = Array(repeating: 0x5B, count: depth)
        bytes.append(contentsOf: Array(repeating: 0x5D, count: depth))
        let val = try JSONParser.parse(bytes, limits: AssetLimits(maxJSONDepth: depth))
        if case .array(let outer) = val {
            #expect(outer.count == 1)
        } else {
            Issue.record("Esperava array")
        }
    }

    // MARK: - glTF / GLB válidos

    @Test func parsesValidGLTFAndComputesAccessorLayout() throws {
        let doc = try GLTFParser.parse(Self.utf8(Self.minimalTriangleJSON))
        #expect(doc.asset.version == "2.0")
        #expect(doc.glbBinary == nil)
        #expect(doc.scene == 0)
        #expect(doc.scenes.count == 1)
        #expect(doc.nodes.count == 2)
        #expect(doc.nodes[0].translation == CajuVec3(1, 2, 3))
        #expect(doc.nodes[0].rotation == CajuQuat.identity)
        #expect(doc.nodes[1].matrix == CajuMat4.identity)
        #expect(doc.meshes.count == 1)
        #expect(doc.meshes[0].primitives[0].mode == .triangles)
        #expect(doc.meshes[0].primitives[0].attributes.count == 2)
        #expect(doc.meshes[0].primitives[0].attributes[0] == ("POSITION", 0))
        #expect(doc.meshes[0].primitives[0].attributes[1] == ("TEXCOORD_0", 1))
        #expect(doc.materialCount == 1)
        #expect(doc.textureCount == 1)
        #expect(doc.imageCount == 1)
        #expect(doc.buffers[0].uri == "data:application/octet-stream;base64,AAAA")

        let posLayout = try doc.accessorLayout(0)
        #expect(
            posLayout == GLTFAccessorLayout(buffer: 0, byteOffset: 0, stride: 20, count: 3, elementSize: 12))

        let uvLayout = try doc.accessorLayout(1)
        #expect(
            uvLayout == GLTFAccessorLayout(buffer: 0, byteOffset: 12, stride: 20, count: 3, elementSize: 8))

        let idxLayout = try doc.accessorLayout(2)
        #expect(
            idxLayout == GLTFAccessorLayout(buffer: 0, byteOffset: 60, stride: 2, count: 3, elementSize: 2))
    }

    @Test func parsesValidGLBWithBINAndUnknownChunk() throws {
        let json = """
            {
              "asset": { "version": "2.1" },
              "buffers": [{ "byteLength": 42 }],
              "bufferViews": [{ "buffer": 0, "byteOffset": 4, "byteLength": 36 }],
              "accessors": [{ "bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3" }],
              "meshes": [{ "primitives": [{ "attributes": { "POSITION": 0 } }] }]
            }
            """
        let binPayload = [UInt8](repeating: 0xAA, count: 42)
        let glb = Self.buildGLB(
            json: json,
            bin: binPayload,
            extraChunks: [(type: 0x5453_4554, data: [1, 2, 3])]
        )
        let doc = try GLTFParser.parse(glb)
        #expect(doc.asset.version == "2.1")
        #expect(doc.buffers[0].uri == nil)
        #expect(doc.buffers[0].byteLength == 42)
        guard let range = doc.glbBinary else {
            Issue.record("glbBinary deveria estar presente")
            return
        }
        #expect(range.count == 44)  // 42 alinhado a 4 bytes
        #expect(glb[range.lowerBound] == 0xAA)
        let layout = try doc.accessorLayout(0)
        #expect(layout == GLTFAccessorLayout(buffer: 0, byteOffset: 4, stride: 12, count: 3, elementSize: 12))
    }

    @Test func mat3ShortUsesAlignedElementSize() throws {
        let json = """
            {
              "asset": { "version": "2.0" },
              "buffers": [{ "byteLength": 48 }],
              "bufferViews": [{ "buffer": 0, "byteLength": 48 }],
              "accessors": [{ "bufferView": 0, "componentType": 5122, "count": 2, "type": "MAT3" }]
            }
            """
        let doc = try GLTFParser.parse(Self.utf8(json))
        let layout = try doc.accessorLayout(0)
        #expect(layout.elementSize == 24)
        #expect(layout.stride == 24)
    }

    // MARK: - Casos malformados e limites

    @Test func rejectsMalformedGLBHeadersAndChunks() {
        // Truncado (< 12 bytes)
        do {
            _ = try GLTFParser.parse([0x67, 0x6C, 0x54, 0x46, 2, 0, 0, 0])
            Issue.record("Esperava truncated")
        } catch let error {
            guard case .truncated = error else {
                Issue.record("Esperava .truncated, veio \(error)")
                return
            }
        }

        // Versão GLB != 2
        var badVersion = Self.buildGLB(json: "{\"asset\":{\"version\":\"2.0\"}}")
        badVersion[4] = 1
        do {
            _ = try GLTFParser.parse(badVersion)
            Issue.record("Esperava invalid version")
        } catch let error {
            guard case .invalid(let ctx, _) = error else {
                Issue.record("Esperava .invalid, veio \(error)")
                return
            }
            #expect(ctx == "glb.version")
        }

        // Primeiro chunk não é JSON
        var wrongFirstChunk = Self.buildGLB(json: "{\"asset\":{\"version\":\"2.0\"}}")
        wrongFirstChunk[16] = 0x42  // 'B'
        wrongFirstChunk[17] = 0x49  // 'I'
        wrongFirstChunk[18] = 0x4E  // 'N'
        wrongFirstChunk[19] = 0x00
        do {
            _ = try GLTFParser.parse(wrongFirstChunk)
            Issue.record("Esperava invalid chunk 0")
        } catch let error {
            guard case .invalid = error else {
                Issue.record("Esperava .invalid, veio \(error)")
                return
            }
        }

        // Múltiplos chunks BIN
        let twoBin = Self.buildGLB(
            json: "{\"asset\":{\"version\":\"2.0\"},\"buffers\":[{\"byteLength\":4}]}",
            bin: [1, 2, 3, 4],
            extraChunks: [(type: 0x004E_4942, data: [5, 6, 7, 8])]
        )
        do {
            _ = try GLTFParser.parse(twoBin)
            Issue.record("Esperava invalid para dois BIN")
        } catch let error {
            guard case .invalid = error else {
                Issue.record("Esperava .invalid, veio \(error)")
                return
            }
        }

        // Buffer 0 com uri no GLB + byteLength maior que chunk BIN
        let uriInGLB = Self.buildGLB(
            json: "{\"asset\":{\"version\":\"2.0\"},\"buffers\":[{\"byteLength\":4,\"uri\":\"a.bin\"}]}",
            bin: [1, 2, 3, 4]
        )
        do {
            _ = try GLTFParser.parse(uriInGLB)
            Issue.record("Esperava invalid para uri no buffer 0 do GLB")
        } catch let error {
            guard case .invalid(let ctx, _) = error else {
                Issue.record("Esperava .invalid, veio \(error)")
                return
            }
            #expect(ctx == "buffers[0].uri")
        }

        let overflowBin = Self.buildGLB(
            json: "{\"asset\":{\"version\":\"2.0\"},\"buffers\":[{\"byteLength\":16}]}",
            bin: [1, 2, 3, 4]
        )
        do {
            _ = try GLTFParser.parse(overflowBin)
            Issue.record("Esperava invalid para buffer 0 maior que BIN")
        } catch let error {
            guard case .invalid(let ctx, _) = error else {
                Issue.record("Esperava .invalid, veio \(error)")
                return
            }
            #expect(ctx == "buffers[0].byteLength")
        }
    }

    @Test func rejectsInvalidGLTFSemanticsAndPaths() {
        let cases: [(name: String, json: String, expectedPrefix: String)] = [
            (
                "versão 1.0",
                #"{"asset":{"version":"1.0"}}"#,
                "asset.version"
            ),
            (
                "bufferView excede buffer",
                #"{"asset":{"version":"2.0"},"buffers":[{"byteLength":10}],"bufferViews":[{"buffer":0,"byteOffset":8,"byteLength":4}]}"#,
                "bufferViews[0].byteLength"
            ),
            (
                "byteStride inválido",
                #"{"asset":{"version":"2.0"},"buffers":[{"byteLength":16}],"bufferViews":[{"buffer":0,"byteLength":16,"byteStride":6}]}"#,
                "bufferViews[0].byteStride"
            ),
            (
                "componentType 5124 proibido",
                #"{"asset":{"version":"2.0"},"accessors":[{"componentType":5124,"count":1,"type":"SCALAR"}]}"#,
                "accessors[0].componentType"
            ),
            (
                "alinhamento de componente",
                #"{"asset":{"version":"2.0"},"buffers":[{"byteLength":16}],"bufferViews":[{"buffer":0,"byteOffset":1,"byteLength":15}],"accessors":[{"bufferView":0,"byteOffset":0,"componentType":5126,"count":1,"type":"SCALAR"}]}"#,
                "accessors[0].byteOffset"
            ),
            (
                "stride menor que elementSize",
                #"{"asset":{"version":"2.0"},"buffers":[{"byteLength":32}],"bufferViews":[{"buffer":0,"byteLength":32,"byteStride":8}],"accessors":[{"bufferView":0,"componentType":5126,"count":2,"type":"VEC3"}]}"#,
                "accessors[0].bufferView"
            ),
            (
                "overflow em count * stride",
                #"{"asset":{"version":"2.0"},"buffers":[{"byteLength":32}],"bufferViews":[{"buffer":0,"byteLength":32}],"accessors":[{"bufferView":0,"componentType":5126,"count":4611686018427387904,"type":"VEC3"}]}"#,
                "accessors[0].count"
            ),
            (
                "índice de primitiva não escalar",
                #"{"asset":{"version":"2.0"},"buffers":[{"byteLength":64}],"bufferViews":[{"buffer":0,"byteLength":64}],"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},{"bufferView":0,"componentType":5123,"count":3,"type":"VEC2"}],"meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1}]}]}"#,
                "meshes[0].primitives[0].indices"
            ),
            (
                "POSITION ausente",
                #"{"asset":{"version":"2.0"},"buffers":[{"byteLength":32}],"bufferViews":[{"buffer":0,"byteLength":32}],"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC2"}],"meshes":[{"primitives":[{"attributes":{"TEXCOORD_0":0}}]}]}"#,
                "meshes[0].primitives[0].attributes"
            ),
            (
                "contagem desigual entre atributos",
                #"{"asset":{"version":"2.0"},"buffers":[{"byteLength":64}],"bufferViews":[{"buffer":0,"byteLength":64}],"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},{"bufferView":0,"componentType":5126,"count":2,"type":"VEC2"}],"meshes":[{"primitives":[{"attributes":{"POSITION":0,"TEXCOORD_0":1}}]}]}"#,
                "meshes[0].primitives[0].attributes.TEXCOORD_0"
            ),
            (
                "ciclo de nós",
                #"{"asset":{"version":"2.0"},"nodes":[{"children":[1]},{"children":[0]}]}"#,
                "nodes[1].children[0]"
            ),
            (
                "nó com 2 pais",
                #"{"asset":{"version":"2.0"},"nodes":[{"children":[2]},{"children":[2]},{}]}"#,
                "nodes[1].children[0]"
            ),
            (
                "matrix + TRS juntos",
                #"{"asset":{"version":"2.0"},"nodes":[{"translation":[0,0,0],"matrix":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}]}"#,
                "nodes[0]"
            ),
            (
                "cena padrão fora da faixa",
                #"{"asset":{"version":"2.0"},"scenes":[],"scene":0}"#,
                "scene"
            ),
        ]

        for testCase in cases {
            do {
                _ = try GLTFParser.parse(Self.utf8(testCase.json))
                Issue.record("Caso '\(testCase.name)' deveria falhar")
            } catch let error {
                switch error {
                case .invalid(let context, _):
                    #expect(context == testCase.expectedPrefix, "Caso '\(testCase.name)'")
                default:
                    Issue.record("Caso '\(testCase.name)' lançou \(error)")
                }
            }
        }
    }

    @Test func sparseAccessorThrowsUnsupported() {
        let json = """
            {
              "asset": { "version": "2.0" },
              "accessors": [
                {
                  "componentType": 5126,
                  "count": 3,
                  "type": "VEC3",
                  "sparse": { "count": 1, "indices": { "bufferView": 0, "componentType": 5123 }, "values": { "bufferView": 1 } }
                }
              ]
            }
            """
        do {
            _ = try GLTFParser.parse(Self.utf8(json))
            Issue.record("Esperava .unsupported para sparse accessor")
        } catch let error {
            guard case .unsupported(let context, _) = error else {
                Issue.record("Esperava .unsupported, veio \(error)")
                return
            }
            #expect(context == "accessors[0].sparse")
        }
    }

    @Test func rejectsCollectionOverMaxElements() {
        let json = #"{"asset":{"version":"2.0"},"nodes":[{},{},{}]}"#
        let limits = AssetLimits(maxElements: 2)
        do {
            _ = try GLTFParser.parse(Self.utf8(json), limits: limits)
            Issue.record("Esperava .limitExceeded")
        } catch let error {
            guard case .limitExceeded = error else {
                Issue.record("Esperava .limitExceeded, veio \(error)")
                return
            }
        }
    }

    // MARK: - Fuzz determinístico

    @Test func fuzzJSONWithSmallLimits() {
        let limits = AssetLimits(
            maxInputBytes: 2048,
            maxOutputBytes: 2048,
            maxImageDimension: 64,
            maxJSONDepth: 12,
            maxElements: 24,
            maxMipLevels: 4
        )
        let seedJSON = Self.utf8(Self.minimalTriangleJSON)

        CajuFuzz.run(seed: 0x1A2B_3C4D, iterations: 2_500) { rng, iteration in
            var input: [UInt8]
            if iteration % 2 == 0 {
                // Entrada aleatória
                let length = Int(rng.nextUInt32() % 512)
                input = [UInt8](repeating: 0, count: length)
                for i in 0..<length {
                    input[i] = UInt8(truncatingIfNeeded: rng.nextUInt32())
                }
            } else {
                // Mutação de entrada válida (flip de bytes e truncamento)
                input = seedJSON
                let flips = 1 + Int(rng.nextUInt32() % 8)
                for _ in 0..<flips where !input.isEmpty {
                    let idx = Int(rng.nextUInt32()) % input.count
                    input[idx] ^= UInt8(1 << (rng.nextUInt32() % 8))
                }
                if rng.nextUInt32() % 3 == 0, input.count > 1 {
                    let newCount = 1 + Int(rng.nextUInt32()) % input.count
                    input.removeLast(input.count - newCount)
                }
            }

            do {
                _ = try JSONParser.parse(input, limits: limits)
            } catch {
                // Só pode retornar ou lançar AssetError
            }
        }
    }

    @Test func fuzzGLTFAndGLBWithSmallLimits() {
        let limits = AssetLimits(
            maxInputBytes: 4096,
            maxOutputBytes: 4096,
            maxImageDimension: 64,
            maxJSONDepth: 16,
            maxElements: 32,
            maxMipLevels: 4
        )
        let validGLTF = Self.utf8(Self.minimalTriangleJSON)
        let validGLB = Self.buildGLB(
            json: Self.minimalTriangleJSON,
            bin: [UInt8](repeating: 0x11, count: 66)
        )

        CajuFuzz.run(seed: 0xCA11_917F, iterations: 2_500) { rng, iteration in
            var input: [UInt8]
            switch iteration % 4 {
            case 0:
                let length = Int(rng.nextUInt32() % 512)
                input = [UInt8](repeating: 0, count: length)
                for i in 0..<length {
                    input[i] = UInt8(truncatingIfNeeded: rng.nextUInt32())
                }
            case 1:
                // Aleatório com cabeçalho GLB plausível
                let length = 12 + Int(rng.nextUInt32() % 256)
                input = [UInt8](repeating: 0, count: length)
                input[0] = 0x67
                input[1] = 0x6C
                input[2] = 0x54
                input[3] = 0x46
                for i in 4..<length {
                    input[i] = UInt8(truncatingIfNeeded: rng.nextUInt32())
                }
            case 2:
                input = validGLTF
            default:
                input = validGLB
            }

            if iteration % 4 >= 2 {
                let flips = 1 + Int(rng.nextUInt32() % 6)
                for _ in 0..<flips where !input.isEmpty {
                    let idx = Int(rng.nextUInt32()) % input.count
                    input[idx] = UInt8(truncatingIfNeeded: rng.nextUInt32())
                }
                if rng.nextUInt32() % 3 == 0, input.count > 1 {
                    let newCount = Int(rng.nextUInt32()) % input.count
                    input.removeLast(input.count - newCount)
                }
            }

            do {
                _ = try GLTFParser.parse(input, limits: limits)
            } catch {
                // Só pode retornar ou lançar AssetError
            }
        }
    }
}

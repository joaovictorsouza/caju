/// Ligações de recursos declaradas num módulo SPIR-V (reflexão mínima, sem dependência externa).
///
/// O contrato do RHI liga recursos por índice e estágio (`setBuffer(index:stage:)`), à moda do Metal; o
/// Vulkan precisa de um `VkDescriptorSetLayout` com o tipo de cada *binding*. Em vez de um layout fixo com
/// todos os 96 *bindings* (estoura `maxPushDescriptors`), cada pipeline monta o layout só com o que os
/// shaders usam, lido daqui (ADR 0024). Puro: testável no host.
public enum CajuVulkanShaderReflection {
    /// Tipo de descritor, com os mesmos valores de `VkDescriptorType`.
    public enum DescriptorKind: UInt32, Sendable, Hashable {
        case sampler = 0
        case combinedImageSampler = 1
        case sampledImage = 2
        case storageImage = 3
        case uniformBuffer = 6
        case storageBuffer = 7
    }

    public struct Binding: Sendable, Hashable {
        public var set: UInt32
        public var binding: UInt32
        public var kind: DescriptorKind
        /// Elementos (arrays de recursos); 1 para recurso único.
        public var count: UInt32

        public init(set: UInt32, binding: UInt32, kind: DescriptorKind, count: UInt32 = 1) {
            self.set = set
            self.binding = binding
            self.kind = kind
            self.count = count
        }
    }

    public enum ReflectionError: Error, Sendable, Equatable {
        case notSPIRV
        case truncated
        /// Array de recursos sem tamanho fixo (`OpTypeRuntimeArray`): fora do contrato.
        case unsizedArray
    }

    /// Lê os *bindings* de descritores (ordenados por `set`, `binding`). Variáveis sem `Binding` são
    /// ignoradas; *push constants* e entradas/saídas também.
    public static func bindings(_ words: UnsafeBufferPointer<UInt32>) throws(ReflectionError) -> [Binding] {
        guard words.count >= 5, words[0] == 0x0723_0203 else { throw .notSPIRV }
        var bindingOf: [UInt32: UInt32] = [:]
        var setOf: [UInt32: UInt32] = [:]
        var bufferBlocks: Set<UInt32> = []
        var types: [UInt32: TypeInfo] = [:]
        var constants: [UInt32: UInt32] = [:]
        var variables: [(id: UInt32, pointer: UInt32, storage: UInt32)] = []

        var index = 5
        while index < words.count {
            let opcode = words[index] & 0xFFFF
            let length = Int(words[index] >> 16)
            guard length > 0, index + length <= words.count else { throw .truncated }
            let operand = { (k: Int) -> UInt32 in words[index + k] }
            switch opcode {
            case 71 where length >= 3:  // OpDecorate
                let decoration = operand(2)
                if decoration == 33, length >= 4 { bindingOf[operand(1)] = operand(3) }
                if decoration == 34, length >= 4 { setOf[operand(1)] = operand(3) }
                if decoration == 3 { bufferBlocks.insert(operand(1)) }  // BufferBlock (SSBO antigo)
            case 25 where length >= 9:  // OpTypeImage: sampled = 1 (amostrada) ou 2 (storage)
                types[operand(1)] = operand(7) == 2 ? .storageImage : .sampledImage
            case 26:  // OpTypeSampler
                types[operand(1)] = .sampler
            case 27:  // OpTypeSampledImage
                types[operand(1)] = .combined
            case 28 where length >= 4:  // OpTypeArray
                types[operand(1)] = .array(element: operand(2), lengthConstant: operand(3))
            case 29:  // OpTypeRuntimeArray
                types[operand(1)] = .runtimeArray(element: operand(2))
            case 30:  // OpTypeStruct
                types[operand(1)] = .structure
            case 32 where length >= 4:  // OpTypePointer
                types[operand(1)] = .pointer(storage: operand(2), pointee: operand(3))
            case 43 where length >= 4:  // OpConstant (inteiros de 32 bits: tamanho de arrays)
                constants[operand(2)] = operand(3)
            case 59 where length >= 4:  // OpVariable
                variables.append((operand(2), operand(1), operand(3)))
            default:
                break
            }
            index += length
        }

        var result: [Binding] = []
        for variable in variables {
            guard let binding = bindingOf[variable.id] else { continue }
            // UniformConstant (0), Uniform (2), StorageBuffer (12).
            guard variable.storage == 0 || variable.storage == 2 || variable.storage == 12,
                case .pointer(_, var pointee)? = types[variable.pointer]
            else { continue }
            var count: UInt32 = 1
            if case .array(let element, let lengthConstant)? = types[pointee] {
                count = constants[lengthConstant] ?? 1
                pointee = element
            } else if case .runtimeArray? = types[pointee] {
                throw .unsizedArray
            }
            let kind: DescriptorKind
            switch types[pointee] {
            case .sampler?: kind = .sampler
            case .sampledImage?: kind = .sampledImage
            case .storageImage?: kind = .storageImage
            case .combined?: kind = .combinedImageSampler
            case .structure?:
                kind =
                    variable.storage == 12 || bufferBlocks.contains(pointee) ? .storageBuffer : .uniformBuffer
            default: continue
            }
            result.append(Binding(set: setOf[variable.id] ?? 0, binding: binding, kind: kind, count: count))
        }
        result.sort { ($0.set, $0.binding) < ($1.set, $1.binding) }
        return result
    }

    private enum TypeInfo {
        case sampler, sampledImage, storageImage, combined, structure
        case array(element: UInt32, lengthConstant: UInt32)
        case runtimeArray(element: UInt32)
        case pointer(storage: UInt32, pointee: UInt32)
    }
}

/// Mapa dos índices por estágio do contrato (espaço do Metal) para os *bindings* do set 0 do Vulkan
/// (ADR 0024): buffers `0..15` vértice e `16..31` fragmento; texturas `32..47`/`48..63`; samplers
/// `64..79`/`80..95`. Os shaders SPIR-V (Slang ou GLSL de teste) declaram `binding` já nesse espaço.
public enum CajuVulkanBindingMap {
    public static let slotsPerStage = 16
    public static let bufferBase = 0
    public static let textureBase = 32
    public static let samplerBase = 64
    /// Total de *bindings* possíveis no set 0.
    public static let count = 96

    public enum Resource: Sendable { case buffer, texture, sampler }

    /// *Binding* do recurso `index` no estágio; `nil` se o índice estoura a faixa ou o estágio é compute.
    @inlinable
    public static func binding(_ resource: Resource, index: Int, fragment: Bool) -> Int? {
        guard index >= 0, index < slotsPerStage else { return nil }
        let base: Int
        switch resource {
        case .buffer: base = bufferBase
        case .texture: base = textureBase
        case .sampler: base = samplerBase
        }
        return base + (fragment ? slotsPerStage : 0) + index
    }

    /// Sampler pareado com uma textura combinada (`sampler2D` de GLSL): mesmo índice e estágio.
    @inlinable
    public static func samplerPairedWithTexture(binding: Int) -> Int? {
        guard binding >= textureBase, binding < samplerBase else { return nil }
        return binding + (samplerBase - textureBase)
    }
}

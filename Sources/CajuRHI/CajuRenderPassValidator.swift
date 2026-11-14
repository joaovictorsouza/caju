/// Regras de validação de um passe de render, compartilhadas por todos os backends (o backend null e a
/// suíte de conformidade usam exatamente as mesmas): cada backend chama antes de gravar o passe.
public enum CajuRenderPassValidator {
    /// Valida attachments, `memoryless`, `resolve` e tamanhos. `lookup` devolve o descritor da textura de
    /// um handle (ou `nil` se o handle for inválido).
    public static func validate(
        _ d: CajuRenderPassDescriptor, maxColorAttachments: Int,
        lookup: (CajuTextureHandle) -> CajuTextureDescriptor?
    ) throws(CajuRHIError) {
        guard d.colorAttachments.count <= maxColorAttachments else {
            throw .invalidDescriptor(.tooManyAttachments)
        }
        guard !d.colorAttachments.isEmpty || d.depthAttachment != nil else {
            throw .invalidDescriptor(.emptyUsage)
        }
        var size: (Int, Int)?
        var samples: Int?
        func check(
            _ t: CajuAttachmentTexture, load: CajuLoadAction, store: CajuStoreAction,
            resolve: CajuAttachmentTexture?
        ) throws(CajuRHIError) {
            guard case .texture(let h) = t else {
                if case .resource(let r) = t { throw .invalidFrameGraph(.unknownResource(index: r.index)) }
                return
            }
            guard let td = lookup(h) else { throw .invalidHandle(index: h.index, generation: h.generation) }
            guard td.usage.contains(.renderTarget) else { throw .invalidDescriptor(.incompatibleUsage) }
            if let size, size != (td.width, td.height) { throw .invalidUsage(.attachmentSizeMismatch) }
            size = (td.width, td.height)
            if let samples, samples != td.sampleCount { throw .invalidUsage(.attachmentSizeMismatch) }
            samples = td.sampleCount
            if td.storage == .memoryless {
                if case .load = load { throw .invalidUsage(.memorylessMustNotPersist) }
                switch store {
                case .store, .storeAndResolve: throw .invalidUsage(.memorylessMustNotPersist)
                case .dontCare, .resolve: break
                }
            }
            switch store {
            case .resolve, .storeAndResolve:
                guard td.sampleCount > 1, let resolve, case .texture(let rh) = resolve,
                    let rd = lookup(rh), rd.sampleCount == 1, (rd.width, rd.height) == (td.width, td.height)
                else { throw .invalidUsage(.resolveTargetNotSingleSample) }
            case .store, .dontCare: break
            }
        }
        for c in d.colorAttachments {
            try check(c.texture, load: c.load, store: c.store, resolve: c.resolveTexture)
        }
        if let depth = d.depthAttachment {
            try check(depth.texture, load: depth.load, store: depth.store, resolve: nil)
        }
    }
}

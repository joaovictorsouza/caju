/// Erro tipado de todas as operações do RHI (`throws(CajuRHIError)`).
///
/// Os casos carregam contexto suficiente para diagnóstico sem alocar `String` no caminho quente:
/// índices e valores numéricos em vez de mensagens formatadas.
public enum CajuRHIError: Error, Sendable, Equatable {
    /// O backend não suporta o recurso pedido (ex.: formato ASTC em GPU sem suporte).
    case unsupported(CajuRHIFeature)
    /// Um descritor viola um limite do dispositivo ou uma regra do contrato.
    case invalidDescriptor(CajuRHIDescriptorIssue)
    /// O handle é nulo, de outra geração (recurso já destruído) ou de outro tipo de recurso.
    case invalidHandle(index: UInt32, generation: UInt32)
    /// Sem memória de GPU ou de CPU para criar o recurso.
    case outOfMemory
    /// A superfície mudou de tamanho ou formato: recrie o *swapchain* (`CajuSwapchain.recreate`).
    case surfaceOutOfDate
    /// A superfície foi destruída pela plataforma (ex.: app foi para segundo plano no Android).
    case surfaceLost
    /// O dispositivo de GPU foi perdido; todos os recursos precisam ser recriados.
    case deviceLost
    /// O uso do recurso viola a regra do passe (ex.: ler um transiente `memoryless` em outro passe).
    case invalidUsage(CajuRHIUsageIssue)
    /// O grafo de quadro é inválido (ciclo, leitura sem escrita, recurso desconhecido).
    case invalidFrameGraph(CajuFrameGraphIssue)
    /// Erro específico do backend, com o código nativo (`MTLCommandBufferError`, `VkResult`).
    case backend(code: Int32)
}

/// Recursos opcionais que um backend pode não oferecer.
public enum CajuRHIFeature: Sendable, Equatable {
    case pixelFormat(CajuPixelFormat)
    case sampleCount(Int)
    case memorylessAttachments
    case computePipelines
    case presentMode(CajuPresentMode)
}

/// Motivos pelos quais um descritor é rejeitado.
public enum CajuRHIDescriptorIssue: Sendable, Equatable {
    case zeroSize
    case exceedsDeviceLimit
    case invalidSampleCount
    case invalidMipCount
    case incompatibleUsage
    case missingShader
    case tooManyAttachments
    case formatMismatch
    case emptyUsage
}

/// Motivos de uso inválido de recursos num passe.
public enum CajuRHIUsageIssue: Sendable, Equatable {
    /// Transiente `memoryless` só aceita `clear`/`dontCare` na carga e `dontCare` no armazenamento.
    case memorylessMustNotPersist
    case encoderAlreadyEnded
    case noPipelineBound
    case drawOutsideRenderPass
    case resolveTargetNotSingleSample
    case attachmentSizeMismatch
}

/// Motivos de rejeição de um grafo de quadro.
public enum CajuFrameGraphIssue: Sendable, Equatable {
    case unknownResource(index: Int)
    case readBeforeWrite(resource: Int, pass: Int)
    case invalidPass(pass: Int)
    case resourceNotAliasable(resource: Int)
    case noOutputs
    case tooManyPasses
    case tooManyResources
}

// Contrato de dispositivo, fila, command buffer e encoders do RHI (ADR 0001, ADR 0015).
//
// Decisões de forma:
// - Protocolos com tipos associados e uso genérico (`some CajuRenderDevice`): sem `any` no caminho quente.
// - Command buffers, encoders e imagens de *swapchain* são `~Copyable`: o compilador impede terminar
//   um encoder duas vezes ou apresentar uma imagem duas vezes.
// - Encoders vivem dentro de um *closure* (`withRenderPass`): não podem escapar do passe.
// - Erros de gravação (dentro do encoder) são acumulados e lançados no fim do passe, como `throws(CajuRHIError)`.
// - Dispositivo e fila não são `Sendable`: pertencem à thread de jogo (ADR 0008).

/// Estágio de shader onde um recurso é ligado.
public enum CajuShaderStage: UInt8, Sendable, Hashable {
    case vertex
    case fragment
    case compute
}

/// Encoder de comandos de desenho dentro de um passe de render.
public protocol CajuRenderEncoder: ~Copyable {
    mutating func setPipeline(_ pipeline: CajuRenderPipelineHandle)
    mutating func setViewport(_ viewport: CajuViewport)
    mutating func setScissor(_ rect: CajuScissorRect)
    /// Fluxo de vértices. `index` é o `bufferIndex` de `CajuVertexBufferLayout`: espaço de índices próprio,
    /// separado dos buffers de uniforme/storage de `setBuffer` (o backend Metal mapeia o fluxo `i` para a
    /// posição `30 - i` da tabela de argumentos; o Vulkan usa o binding `i`).
    mutating func setVertexBuffer(_ buffer: CajuBufferHandle, offset: Int, index: Int)
    /// Buffer de uniforme/storage no estágio dado; `index` é o `[[buffer(n)]]` / `binding = n` do shader.
    mutating func setBuffer(_ buffer: CajuBufferHandle, offset: Int, index: Int, stage: CajuShaderStage)
    /// Dados pequenos inline (constantes por draw, até 4 KB), sem criar buffer.
    mutating func setBytes(_ bytes: UnsafeRawBufferPointer, index: Int, stage: CajuShaderStage)
    mutating func setTexture(_ texture: CajuTextureHandle, index: Int, stage: CajuShaderStage)
    mutating func setSampler(_ sampler: CajuSamplerHandle, index: Int, stage: CajuShaderStage)
    mutating func draw(vertexCount: Int, instanceCount: Int, firstVertex: Int, firstInstance: Int)
    mutating func drawIndexed(
        indexCount: Int, instanceCount: Int, indexBuffer: CajuBufferHandle, indexType: CajuIndexType,
        indexOffset: Int, baseVertex: Int, firstInstance: Int)
}

extension CajuRenderEncoder where Self: ~Copyable {
    /// Desenho simples sem instanciamento.
    public mutating func draw(vertexCount: Int) {
        draw(vertexCount: vertexCount, instanceCount: 1, firstVertex: 0, firstInstance: 0)
    }
}

/// Encoder de comandos de compute.
public protocol CajuComputeEncoder: ~Copyable {
    mutating func setPipeline(_ pipeline: CajuComputePipelineHandle)
    mutating func setBuffer(_ buffer: CajuBufferHandle, offset: Int, index: Int)
    mutating func setBytes(_ bytes: UnsafeRawBufferPointer, index: Int)
    mutating func setTexture(_ texture: CajuTextureHandle, index: Int)
    mutating func dispatch(
        groupsX: Int, groupsY: Int, groupsZ: Int, threadsPerGroupX: Int, threadsPerGroupY: Int,
        threadsPerGroupZ: Int)
}

/// Encoder de cópias (uploads e *readbacks* GPU-GPU).
public protocol CajuCopyEncoder: ~Copyable {
    mutating func copyBuffer(
        from source: CajuBufferHandle, sourceOffset: Int, to destination: CajuBufferHandle,
        destinationOffset: Int, size: Int)
    mutating func copyBufferToTexture(
        _ buffer: CajuBufferHandle, bufferOffset: Int, bytesPerRow: Int, to texture: CajuTextureHandle,
        mipLevel: Int, slice: Int, width: Int, height: Int)
    mutating func generateMipmaps(for texture: CajuTextureHandle)
}

/// Sequência de passes gravados para uma submissão.
public protocol CajuCommandBuffer: ~Copyable {
    associatedtype RenderEncoder: CajuRenderEncoder & ~Copyable
    associatedtype ComputeEncoder: CajuComputeEncoder & ~Copyable
    associatedtype CopyEncoder: CajuCopyEncoder & ~Copyable

    /// Grava um passe de render. Lança o primeiro erro de validação/gravação ao fim do passe.
    mutating func withRenderPass(
        _ descriptor: CajuRenderPassDescriptor, _ body: (inout RenderEncoder) -> Void
    ) throws(CajuRHIError)

    mutating func withComputePass(label: String, _ body: (inout ComputeEncoder) -> Void)
        throws(CajuRHIError)

    mutating func withCopyPass(label: String, _ body: (inout CopyEncoder) -> Void) throws(CajuRHIError)

    /// Agenda a apresentação da imagem ao fim da execução deste command buffer.
    mutating func present(_ image: consuming CajuSwapchainImage) throws(CajuRHIError)
}

/// Fila de submissão de uma GPU.
public protocol CajuQueue {
    associatedtype CommandBuffer: CajuCommandBuffer & ~Copyable

    func makeCommandBuffer(label: String) throws(CajuRHIError) -> CommandBuffer

    /// Envia o command buffer à GPU (consome-o). Não bloqueia até o fim da execução.
    func submit(_ commandBuffer: consuming CommandBuffer) throws(CajuRHIError)

    /// Bloqueia até a fila ficar ociosa (usar em transições de ciclo de vida e testes, nunca por quadro).
    func waitUntilIdle() throws(CajuRHIError)
}

/// Dispositivo de GPU: cria recursos e entrega a fila e o *swapchain*.
///
/// Todos os métodos devem ser chamados da thread de jogo. Handles são válidos até `destroy`.
public protocol CajuRenderDevice: AnyObject {
    associatedtype Queue: CajuQueue
    associatedtype Swapchain: CajuSwapchain

    var capabilities: CajuDeviceCapabilities { get }
    var queue: Queue { get }

    func createBuffer(_ descriptor: CajuBufferDescriptor) throws(CajuRHIError) -> CajuBufferHandle
    func createTexture(_ descriptor: CajuTextureDescriptor) throws(CajuRHIError) -> CajuTextureHandle
    func createSampler(_ descriptor: CajuSamplerDescriptor) throws(CajuRHIError) -> CajuSamplerHandle
    func createShaderModule(_ descriptor: CajuShaderModuleDescriptor) throws(CajuRHIError)
        -> CajuShaderHandle
    func createRenderPipeline(_ descriptor: CajuRenderPipelineDescriptor) throws(CajuRHIError)
        -> CajuRenderPipelineHandle
    func createComputePipeline(_ descriptor: CajuComputePipelineDescriptor) throws(CajuRHIError)
        -> CajuComputePipelineHandle
    func createSwapchain(_ surface: CajuSurfaceDescriptor) throws(CajuRHIError) -> Swapchain

    func destroy(_ buffer: CajuBufferHandle)
    func destroy(_ texture: CajuTextureHandle)
    func destroy(_ sampler: CajuSamplerHandle)
    func destroy(_ shader: CajuShaderHandle)
    func destroy(_ pipeline: CajuRenderPipelineHandle)
    func destroy(_ pipeline: CajuComputePipelineHandle)

    /// Copia dados da CPU para um buffer `shared` (sem command buffer).
    func writeBuffer(_ buffer: CajuBufferHandle, offset: Int, bytes: UnsafeRawBufferPointer)
        throws(CajuRHIError)

    /// Envia texels da CPU para a região de um mip de uma textura (caminho de upload síncrono simples;
    /// uploads grandes passam por buffer de *staging* e `CajuCopyEncoder`, sob `CajuUploadBudget`).
    func writeTexture(
        _ texture: CajuTextureHandle, mipLevel: Int, slice: Int, width: Int, height: Int, bytesPerRow: Int,
        bytes: UnsafeRawBufferPointer
    ) throws(CajuRHIError)

    /// Textura transitória do *frame graph* para o `slot` de aliasing. Texturas no mesmo `slot` nunca
    /// vivem ao mesmo tempo e podem compartilhar memória. A mesma chamada com o mesmo `(slot, descritor)`
    /// devolve o mesmo handle quadro a quadro; descritores diferentes no mesmo slot têm handles distintos
    /// que compartilham memória. `slot` negativo pede textura exclusiva (usado por `memoryless`).
    func transientTexture(_ descriptor: CajuTextureDescriptor, slot: Int) throws(CajuRHIError)
        -> CajuTextureHandle

    /// Libera todas as texturas transitórias (ex.: ao receber aviso de pouca memória ou ir ao fundo).
    func releaseTransients()
}

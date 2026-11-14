/// Tipo de superfície nativa onde o *swapchain* apresenta.
public enum CajuNativeSurfaceKind: UInt8, Sendable, Hashable {
    /// `CAMetalLayer` (iOS, macOS).
    case metalLayer
    /// `ANativeWindow` (Android).
    case androidNativeWindow
    /// Sem janela: backends de teste (`CajuNullDevice`) e renderização fora da tela.
    case headless
}

/// Modo de apresentação.
public enum CajuPresentMode: UInt8, Sendable, Hashable {
    /// V-sync clássico; sempre disponível.
    case fifo
    /// Substitui o quadro pendente (baixa latência sem *tearing*), quando suportado.
    case mailbox
    /// Sem sincronização (pode causar *tearing*), quando suportado.
    case immediate
}

/// Descreve a superfície nativa e como apresentar nela.
///
/// É um valor `Sendable`: a plataforma produz o descritor (thread de UI) e a thread de jogo o consome.
/// `nativeHandle` guarda o endereço do objeto nativo como inteiro, o que mantém o tipo `Sendable`
/// sem `@unchecked`; o backend o converte de volta com `UnsafeRawPointer(bitPattern:)`.
public struct CajuSurfaceDescriptor: Sendable, Equatable {
    public var kind: CajuNativeSurfaceKind
    public var nativeHandle: UInt
    /// Tamanho em pixels (não em pontos).
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Fator de escala da tela (pixels por ponto), para informar a UI.
    public var scale: Float
    public var preferredFormat: CajuPixelFormat
    public var presentMode: CajuPresentMode

    public init(
        kind: CajuNativeSurfaceKind,
        nativeHandle: UInt,
        pixelWidth: Int,
        pixelHeight: Int,
        scale: Float = 1,
        preferredFormat: CajuPixelFormat = .bgra8UnormSRGB,
        presentMode: CajuPresentMode = .fifo
    ) {
        self.kind = kind
        self.nativeHandle = nativeHandle
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.preferredFormat = preferredFormat
        self.presentMode = presentMode
    }
}

/// Imagem do *swapchain* adquirida para um quadro. Deve ser apresentada **uma vez**
/// (`CajuCommandBuffer.present`), por isso é `~Copyable`.
public struct CajuSwapchainImage: ~Copyable, Sendable {
    /// Textura do quadro; válida só até a apresentação.
    public let texture: CajuTextureHandle
    public let width: Int
    public let height: Int
    public let format: CajuPixelFormat
    /// Posição da imagem no *swapchain* (índice de quadro em voo no Metal).
    public let imageIndex: Int

    public init(
        texture: CajuTextureHandle, width: Int, height: Int, format: CajuPixelFormat, imageIndex: Int
    ) {
        self.texture = texture
        self.width = width
        self.height = height
        self.format = format
        self.imageIndex = imageIndex
    }
}

/// Cadeia de imagens apresentáveis de uma superfície.
///
/// Perda ou mudança da superfície aparece como `CajuRHIError.surfaceOutOfDate`/`.surfaceLost` em
/// `acquireNextImage`; o chamador então chama `recreate` com o descritor novo (ou espera a plataforma
/// entregar uma superfície nova) e tenta de novo. Recursos que não dependem da superfície sobrevivem.
public protocol CajuSwapchain: AnyObject {
    var format: CajuPixelFormat { get }
    var pixelWidth: Int { get }
    var pixelHeight: Int { get }

    /// Adquire a próxima imagem para desenhar.
    func acquireNextImage() throws(CajuRHIError) -> CajuSwapchainImage

    /// Recria a cadeia para a superfície nova (tamanho, formato ou objeto nativo diferentes).
    func recreate(_ surface: CajuSurfaceDescriptor) throws(CajuRHIError)

    /// Libera os recursos nativos da superfície (ex.: ao ir para segundo plano). Depois de
    /// `releaseSurface`, `acquireNextImage` falha com `.surfaceLost` até um `recreate`.
    func releaseSurface()
}

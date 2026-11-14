/// Tipo da superfície nativa entregue pela plataforma (espelha `CajuNativeSurfaceKind` do RHI; a
/// camada de render faz a conversão, porque `CajuPlatform` não depende de `CajuRHI`).
public enum CajuPlatformSurfaceKind: UInt8, Sendable, Hashable {
    /// `CAMetalLayer` (iOS, macOS).
    case metalLayer
    /// `ANativeWindow` (Android).
    case androidNativeWindow
    /// Sem janela (testes, renderização fora da tela).
    case headless
}

/// Margens em pixels (área segura: notch, barra de gestos, cantos arredondados).
public struct CajuEdgeInsets: Sendable, Equatable {
    public var top: Float
    public var left: Float
    public var bottom: Float
    public var right: Float

    public init(top: Float = 0, left: Float = 0, bottom: Float = 0, right: Float = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let zero = CajuEdgeInsets()
}

/// Superfície de apresentação de uma janela, como a plataforma a descreve.
///
/// Valor `Sendable`: a thread de UI o cria e o laço de jogo o consome. `nativeHandle` é o endereço do
/// objeto nativo como inteiro (mantém o tipo `Sendable` sem `@unchecked`); o dono do objeto é a
/// plataforma e ele só é válido entre `surfaceCreated` e `surfaceDestroyed`.
public struct CajuPlatformSurface: Sendable, Equatable {
    public var kind: CajuPlatformSurfaceKind
    public var nativeHandle: UInt
    /// Tamanho em pixels (não em pontos).
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Pixels por ponto (3 em iPhones Pro; 1 a 3,5 em Androids).
    public var scale: Float
    public var safeArea: CajuEdgeInsets
    /// Taxa de atualização máxima da tela em Hz (60, 120...).
    public var maximumFramesPerSecond: Int

    public init(
        kind: CajuPlatformSurfaceKind, nativeHandle: UInt, pixelWidth: Int, pixelHeight: Int,
        scale: Float = 1, safeArea: CajuEdgeInsets = .zero, maximumFramesPerSecond: Int = 60
    ) {
        self.kind = kind
        self.nativeHandle = nativeHandle
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.safeArea = safeArea
        self.maximumFramesPerSecond = maximumFramesPerSecond
    }
}

/// Configuração de janela (macOS e hosts desktop; ignorada em iOS/Android).
public struct CajuWindowConfiguration: Sendable, Equatable {
    public var title: String
    /// Tamanho inicial em pontos.
    public var width: Int
    public var height: Int
    public var isResizable: Bool

    public init(title: String, width: Int = 1280, height: Int = 720, isResizable: Bool = true) {
        self.title = title
        self.width = width
        self.height = height
        self.isResizable = isResizable
    }
}

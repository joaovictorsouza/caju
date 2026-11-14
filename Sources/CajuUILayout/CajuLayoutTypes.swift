import CajuMath

/// Alinhamento horizontal de um filho dentro do espaço que sobra.
public enum CajuHorizontalAlignment: Sendable, Equatable {
    case leading, center, trailing

    /// Fração do espaço livre antes do filho (0, 0,5 ou 1).
    @inlinable var factor: Float {
        switch self {
        case .leading: 0
        case .center: 0.5
        case .trailing: 1
        }
    }
}

/// Alinhamento vertical de um filho dentro do espaço que sobra.
public enum CajuVerticalAlignment: Sendable, Equatable {
    case top, center, bottom

    @inlinable var factor: Float {
        switch self {
        case .top: 0
        case .center: 0.5
        case .bottom: 1
        }
    }
}

/// Alinhamento nos dois eixos (`ZStack`, `frame`).
public struct CajuAlignment: Sendable, Equatable {
    public var horizontal: CajuHorizontalAlignment
    public var vertical: CajuVerticalAlignment

    public init(horizontal: CajuHorizontalAlignment, vertical: CajuVerticalAlignment) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    public static let center = CajuAlignment(horizontal: .center, vertical: .center)
    public static let topLeading = CajuAlignment(horizontal: .leading, vertical: .top)
    public static let topTrailing = CajuAlignment(horizontal: .trailing, vertical: .top)
    public static let bottomLeading = CajuAlignment(horizontal: .leading, vertical: .bottom)
    public static let bottomTrailing = CajuAlignment(horizontal: .trailing, vertical: .bottom)
}

/// Margens internas (`padding`). `leading` é a esquerda (sem espelhamento RTL por enquanto).
public struct CajuInsets: Sendable, Equatable {
    public var top: Float
    public var leading: Float
    public var bottom: Float
    public var trailing: Float

    public init(top: Float = 0, leading: Float = 0, bottom: Float = 0, trailing: Float = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public init(all value: Float) { self.init(top: value, leading: value, bottom: value, trailing: value) }

    public init(horizontal: Float, vertical: Float) {
        self.init(top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal)
    }

    public static let zero = CajuInsets()
}

/// Retângulo em coordenadas de UI (origem no canto superior esquerdo, y para baixo).
public struct CajuUIRect: Sendable, Equatable {
    public var origin: CajuVec2
    public var size: CajuVec2

    @inlinable public init(origin: CajuVec2, size: CajuVec2) {
        self.origin = origin
        self.size = size
    }

    @inlinable public init(x: Float, y: Float, width: Float, height: Float) {
        self.init(origin: CajuVec2(x, y), size: CajuVec2(width, height))
    }

    public static let zero = CajuUIRect(x: 0, y: 0, width: 0, height: 0)

    @inlinable public var maxX: Float { origin.x + size.x }
    @inlinable public var maxY: Float { origin.y + size.y }

    /// Ponto dentro do retângulo (bordas esquerda/superior inclusivas, direita/inferior exclusivas).
    @inlinable public func contains(_ p: CajuVec2) -> Bool {
        p.x >= origin.x && p.x < maxX && p.y >= origin.y && p.y < maxY
    }
}

/// Faixa de tamanhos que um conteúdo aceita: mínimo, ideal e máximo por eixo.
///
/// `max` pode ser `.infinity` (conteúdo flexível, como `Color` ou `Spacer`).
public struct CajuSizeRange: Sendable, Equatable {
    public var min: CajuVec2
    public var ideal: CajuVec2
    public var max: CajuVec2

    public init(min: CajuVec2, ideal: CajuVec2, max: CajuVec2) {
        self.min = min
        self.ideal = ideal
        self.max = max
    }

    /// Conteúdo de tamanho fixo (texto já medido, imagem).
    public static func fixed(_ size: CajuVec2) -> CajuSizeRange {
        CajuSizeRange(min: size, ideal: size, max: size)
    }

    /// Conteúdo que se estica até preencher o espaço proposto (como `Color`/`Rectangle`).
    public static func flexible(ideal: CajuVec2 = CajuVec2(10, 10)) -> CajuSizeRange {
        CajuSizeRange(min: .zero, ideal: ideal, max: CajuVec2(.infinity, .infinity))
    }

    static let zero = CajuSizeRange.fixed(.zero)
}

/// Restrições do modificador `frame`. Largura/altura fixas vencem as faixas `min`/`max`.
public struct CajuFrameConstraints: Sendable, Equatable {
    public var width: Float?
    public var height: Float?
    public var minWidth: Float?
    public var maxWidth: Float?
    public var minHeight: Float?
    public var maxHeight: Float?
    /// Onde o filho fica dentro do quadro quando ele é maior que o filho.
    public var alignment: CajuAlignment

    public init(
        width: Float? = nil, height: Float? = nil,
        minWidth: Float? = nil, maxWidth: Float? = nil,
        minHeight: Float? = nil, maxHeight: Float? = nil,
        alignment: CajuAlignment = .center
    ) {
        self.width = width
        self.height = height
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.alignment = alignment
    }
}

/// Tipo de um nó de layout.
public enum CajuLayoutKind: Sendable, Equatable {
    /// Filhos da esquerda para a direita.
    case hStack(spacing: Float = 0, alignment: CajuVerticalAlignment = .center)
    /// Filhos de cima para baixo.
    case vStack(spacing: Float = 0, alignment: CajuHorizontalAlignment = .center)
    /// Filhos empilhados em profundidade; o último fica por cima.
    case zStack(alignment: CajuAlignment = .center)
    /// Modificador de tamanho; no máximo 1 filho.
    case frame(CajuFrameConstraints)
    /// Margens internas; no máximo 1 filho.
    case padding(CajuInsets)
    /// Espaço flexível ao longo do eixo da pilha pai (nos dois eixos fora de pilhas).
    case spacer(minLength: Float = 0)
    /// Folha com faixa de tamanhos própria (texto, imagem, cor); sem filhos.
    case leaf(CajuSizeRange)

    var maxChildren: Int {
        switch self {
        case .hStack, .vStack, .zStack: Int.max
        case .frame, .padding: 1
        case .spacer, .leaf: 0
        }
    }
}

/// Identificador estável de um nó. Fica inválido quando o nó é removido (geração).
public struct CajuLayoutNodeID: Sendable, Hashable {
    @usableFromInline let index: Int32
    @usableFromInline let generation: UInt32
}

/// Erros das operações de edição da árvore.
public enum CajuLayoutError: Error, Sendable, Equatable {
    /// O identificador não existe mais (nó removido) ou nunca existiu.
    case invalidNode
    /// A árvore já tem raiz.
    case rootAlreadyExists
    /// O pai não aceita mais filhos (folha, `Spacer` ou `frame`/`padding` que já têm um).
    case parentCannotHaveMoreChildren
    /// Profundidade acima de ``CajuLayoutTree/maxDepth``.
    case depthExceeded
    /// Mais nós que ``CajuLayoutTree/maxNodes``.
    case capacityExceeded
}

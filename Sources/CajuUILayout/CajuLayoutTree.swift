import CajuMath

/// Árvore retida de layout no estilo SwiftUI: o pai propõe um tamanho, o filho escolhe dentro da sua
/// faixa (mínimo/ideal/máximo) e o pai o posiciona. Puro, sem GPU, sem Foundation (ADR 0002).
///
/// Os nós vivem em arrays contíguos; `layout(in:)` não aloca depois que a árvore atingiu o tamanho
/// estável, e só recalcula quando algo mudou ou o tamanho disponível é outro.
///
/// ```swift
/// var tree = CajuLayoutTree()
/// let root = try tree.add(.vStack(spacing: 8))
/// let title = try tree.add(.leaf(.fixed(CajuVec2(120, 24))), to: root)
/// _ = try tree.add(.spacer(), to: root)
/// tree.layout(in: CajuVec2(200, 400))
/// tree.frame(of: title)  // x: 40, y: 0, 120 × 24
/// ```
public struct CajuLayoutTree: Sendable {
    /// Profundidade máxima (a raiz tem profundidade 1); protege a recursão do layout.
    public static let maxDepth = 128
    /// Número máximo de nós.
    public static let maxNodes = 1 << 20

    struct Node: Sendable {
        var kind: CajuLayoutKind
        var parent: Int32 = -1
        var firstChild: Int32 = -1
        var lastChild: Int32 = -1
        var prevSibling: Int32 = -1
        var nextSibling: Int32 = -1
        var depth: UInt16 = 1
        var hitTestable = false
        var alive = true
    }

    var nodes: [Node] = []
    var generations: [UInt32] = []
    var freeList: [Int32] = []
    /// Faixa de tamanho de cada nó (passo de baixo para cima).
    var ranges: [CajuSizeRange] = []
    /// Moldura absoluta de cada nó (saída do layout).
    var frames: [CajuUIRect] = []
    /// Rascunhos do passo de pilhas (tamanho no eixo principal e "congelado").
    var mainSizes: [Float] = []
    var frozen: [Bool] = []

    var root: Int32 = -1
    var isDirty = true
    var lastAvailable = CajuVec2(-1, -1)
    /// Quantas vezes o layout rodou de fato (observável em testes).
    var layoutPasses = 0
    var liveCount = 0

    public init() {}

    /// Cria a árvore reservando espaço para `capacity` nós (evita realocar durante a construção).
    public init(capacity: Int) {
        let n = max(0, min(capacity, Self.maxNodes))
        nodes.reserveCapacity(n)
        generations.reserveCapacity(n)
        ranges.reserveCapacity(n)
        frames.reserveCapacity(n)
        mainSizes.reserveCapacity(n)
        frozen.reserveCapacity(n)
    }

    /// Quantidade de nós vivos.
    public var count: Int { liveCount }

    /// Raiz da árvore, se existir.
    public var rootID: CajuLayoutNodeID? { root >= 0 ? id(at: root) : nil }

    // MARK: - Edição

    /// Adiciona um nó. `parent == nil` cria a raiz (só uma).
    @discardableResult
    public mutating func add(
        _ kind: CajuLayoutKind, to parent: CajuLayoutNodeID? = nil
    ) throws(CajuLayoutError) -> CajuLayoutNodeID {
        var parentIndex: Int32 = -1
        var depth: UInt16 = 1
        if let parent {
            guard let p = resolve(parent) else { throw .invalidNode }
            guard childCount(of: p) < nodes[Int(p)].kind.maxChildren else {
                throw .parentCannotHaveMoreChildren
            }
            guard Int(nodes[Int(p)].depth) < Self.maxDepth else { throw .depthExceeded }
            parentIndex = p
            depth = nodes[Int(p)].depth + 1
        } else if root >= 0 {
            throw .rootAlreadyExists
        }
        guard liveCount < Self.maxNodes else { throw .capacityExceeded }

        var node = Node(kind: kind.normalized)
        node.parent = parentIndex
        node.depth = depth
        node.hitTestable = kind.isHitTestableByDefault
        let index: Int32
        if let reused = freeList.popLast() {
            index = reused
            nodes[Int(index)] = node
        } else {
            index = Int32(nodes.count)
            nodes.append(node)
            generations.append(0)
            ranges.append(.zero)
            frames.append(.zero)
            mainSizes.append(0)
            frozen.append(false)
        }
        if parentIndex >= 0 {
            let p = Int(parentIndex)
            let last = nodes[p].lastChild
            nodes[Int(index)].prevSibling = last
            if last >= 0 { nodes[Int(last)].nextSibling = index } else { nodes[p].firstChild = index }
            nodes[p].lastChild = index
        } else {
            root = index
        }
        liveCount += 1
        isDirty = true
        return id(at: index)
    }

    /// Troca o tipo de um nó existente, mantendo filhos. Falha se o novo tipo não comporta os filhos atuais.
    public mutating func update(_ node: CajuLayoutNodeID, kind: CajuLayoutKind) throws(CajuLayoutError) {
        guard let i = resolve(node) else { throw .invalidNode }
        guard childCount(of: i) <= kind.maxChildren else { throw .parentCannotHaveMoreChildren }
        let normalized = kind.normalized
        guard nodes[Int(i)].kind != normalized else { return }
        nodes[Int(i)].kind = normalized
        isDirty = true
    }

    /// Define se o nó recebe toques em ``hitTest(_:)``. Padrão: folhas sim; contêineres e `Spacer` não.
    public mutating func setHitTestable(_ node: CajuLayoutNodeID, _ value: Bool) throws(CajuLayoutError) {
        guard let i = resolve(node) else { throw .invalidNode }
        nodes[Int(i)].hitTestable = value
    }

    /// Remove o nó e toda a sua subárvore. Os identificadores removidos deixam de valer.
    public mutating func remove(_ node: CajuLayoutNodeID) throws(CajuLayoutError) {
        guard let i = resolve(node) else { throw .invalidNode }
        let n = nodes[Int(i)]
        if n.prevSibling >= 0 { nodes[Int(n.prevSibling)].nextSibling = n.nextSibling }
        if n.nextSibling >= 0 { nodes[Int(n.nextSibling)].prevSibling = n.prevSibling }
        if n.parent >= 0 {
            let p = Int(n.parent)
            if nodes[p].firstChild == i { nodes[p].firstChild = n.nextSibling }
            if nodes[p].lastChild == i { nodes[p].lastChild = n.prevSibling }
        } else {
            root = -1
        }
        // Libera a subárvore sem recursão: desce até uma folha, libera, sobe.
        var cur = i
        while true {
            let c = nodes[Int(cur)]
            if c.firstChild >= 0 {
                cur = c.firstChild
                continue
            }
            let parent = c.parent
            let next = c.nextSibling
            release(cur)
            if cur == i { break }
            if next >= 0 {
                cur = next
            } else {
                cur = parent
                nodes[Int(cur)].firstChild = -1  // todos os filhos já foram liberados
            }
        }
        isDirty = true
    }

    // MARK: - Consulta

    /// Moldura absoluta (coordenadas da raiz) calculada pelo último ``layout(in:)``.
    public func frame(of node: CajuLayoutNodeID) -> CajuUIRect? {
        guard let i = resolve(node) else { return nil }
        return frames[Int(i)]
    }

    /// Filhos de um nó, em ordem. Aloca: use fora do caminho quente (inspeção, depuração).
    public func children(of node: CajuLayoutNodeID) -> [CajuLayoutNodeID] {
        guard let i = resolve(node) else { return [] }
        var result: [CajuLayoutNodeID] = []
        var c = nodes[Int(i)].firstChild
        while c >= 0 {
            result.append(id(at: c))
            c = nodes[Int(c)].nextSibling
        }
        return result
    }

    /// Marca a árvore como suja (por exemplo, quando o conteúdo de uma folha mudou de tamanho).
    public mutating func invalidate() { isDirty = true }

    // MARK: - Internos

    func id(at index: Int32) -> CajuLayoutNodeID {
        CajuLayoutNodeID(index: index, generation: generations[Int(index)])
    }

    func resolve(_ id: CajuLayoutNodeID) -> Int32? {
        let i = Int(id.index)
        guard i >= 0, i < nodes.count, nodes[i].alive, generations[i] == id.generation else { return nil }
        return id.index
    }

    func childCount(of index: Int32) -> Int {
        var n = 0
        var c = nodes[Int(index)].firstChild
        while c >= 0 {
            n += 1
            c = nodes[Int(c)].nextSibling
        }
        return n
    }

    private mutating func release(_ index: Int32) {
        let i = Int(index)
        nodes[i].alive = false
        generations[i] &+= 1
        freeList.append(index)
        liveCount -= 1
    }
}

extension CajuLayoutKind {
    /// Valores negativos ou `NaN` viram 0 (dado vindo de fora é hostil); `infinity` só vale como máximo.
    var normalized: CajuLayoutKind {
        func f(_ v: Float) -> Float { v.isNaN || v < 0 ? 0 : (v.isFinite ? v : 0) }
        func opt(_ v: Float?) -> Float? { v.map(f) }
        func hi(_ v: Float?) -> Float? { v.map { $0.isNaN || $0 < 0 ? 0 : $0 } }  // aceita .infinity
        func vec(_ v: CajuVec2) -> CajuVec2 { CajuVec2(f(v.x), f(v.y)) }
        func hiVec(_ v: CajuVec2) -> CajuVec2 {
            CajuVec2(v.x.isNaN || v.x < 0 ? 0 : v.x, v.y.isNaN || v.y < 0 ? 0 : v.y)
        }
        switch self {
        case .hStack(let s, let a): return .hStack(spacing: f(s), alignment: a)
        case .vStack(let s, let a): return .vStack(spacing: f(s), alignment: a)
        case .zStack: return self
        case .spacer(let m): return .spacer(minLength: f(m))
        case .padding(let i):
            return .padding(
                CajuInsets(top: f(i.top), leading: f(i.leading), bottom: f(i.bottom), trailing: f(i.trailing))
            )
        case .frame(let c):
            return .frame(
                CajuFrameConstraints(
                    width: opt(c.width), height: opt(c.height),
                    minWidth: opt(c.minWidth), maxWidth: hi(c.maxWidth),
                    minHeight: opt(c.minHeight), maxHeight: hi(c.maxHeight),
                    alignment: c.alignment))
        case .leaf(let r):
            let mn = vec(r.min)
            let mx = hiVec(r.max)
            let hiClamped = CajuVec2(Swift.max(mx.x, mn.x), Swift.max(mx.y, mn.y))
            let ideal = vec(r.ideal)
            return .leaf(
                CajuSizeRange(
                    min: mn,
                    ideal: CajuVec2(
                        Swift.min(Swift.max(ideal.x, mn.x), hiClamped.x),
                        Swift.min(Swift.max(ideal.y, mn.y), hiClamped.y)),
                    max: hiClamped))
        }
    }

    var isHitTestableByDefault: Bool {
        if case .leaf = self { return true }
        return false
    }
}

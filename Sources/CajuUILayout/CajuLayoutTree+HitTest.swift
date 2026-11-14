import CajuMath

extension CajuLayoutTree {
    /// Nó mais acima sob `point` (coordenadas da raiz), ou `nil`.
    ///
    /// "Mais acima" é o último na ordem de pintura (profundidade primeiro, irmãos em ordem), então um
    /// filho vence o pai e o irmão posterior vence o anterior. Só concorrem nós com
    /// ``setHitTestable(_:_:)`` ligado, e filhos fora da moldura do pai não são testados (equivale a
    /// recortar). Sem alocação e sem recursão. Usa as molduras do último ``layout(in:)``.
    public func hitTest(_ point: CajuVec2) -> CajuLayoutNodeID? {
        guard root >= 0 else { return nil }
        var best: Int32 = -1
        var cur = root
        while true {
            let node = nodes[Int(cur)]
            if frames[Int(cur)].contains(point) {
                if node.hitTestable { best = cur }
                if node.firstChild >= 0 {
                    cur = node.firstChild
                    continue
                }
            }
            // Próximo irmão; se não houver, sobe até achar um.
            while nodes[Int(cur)].nextSibling < 0 {
                cur = nodes[Int(cur)].parent
                if cur < 0 { return best >= 0 ? id(at: best) : nil }
            }
            cur = nodes[Int(cur)].nextSibling
        }
    }
}

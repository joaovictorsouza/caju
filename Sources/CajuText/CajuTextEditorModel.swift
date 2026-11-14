/// Modelo de edição de texto (sem UI): conteúdo, cursor/seleção e texto em composição (IME).
///
/// Os deslocamentos são em *grafemas* (`Character`), então o cursor nunca cai no meio de um emoji ou
/// de letra com acento combinado. Use `scalarOffset` para falar com `CajuTextLayout`.
///
/// ```swift
/// var editor = CajuTextEditorModel(text: "olá")
/// editor.insert(" mundo")      // "olá mundo", cursor no fim
/// editor.deleteBackward()      // "olá mund"
/// ```
public struct CajuTextEditorModel: Sendable, Equatable {
    public private(set) var text: String
    /// Extremidade fixa da seleção (grafemas).
    public private(set) var anchor: Int
    /// Extremidade móvel / posição do cursor (grafemas).
    public private(set) var caret: Int
    /// Faixa em composição de IME (grafemas); `nil` fora de composição.
    public private(set) var markedRange: Range<Int>?
    /// Limite de grafemas; inserções que ultrapassam são truncadas.
    public var maxLength: Int?
    public private(set) var length: Int

    public init(text: String = "", maxLength: Int? = nil) {
        self.maxLength = maxLength
        let t = maxLength.map { String(text.prefix($0)) } ?? text
        self.text = t
        length = t.count
        anchor = length
        caret = length
        markedRange = nil
    }

    public var selection: Range<Int> { min(anchor, caret)..<max(anchor, caret) }
    public var hasSelection: Bool { anchor != caret }
    public var selectedText: String { substring(selection) }

    // MARK: Seleção e movimento

    public mutating func setSelection(anchor: Int, caret: Int) {
        self.anchor = clamp(anchor)
        self.caret = clamp(caret)
    }

    public mutating func selectAll() {
        anchor = 0
        caret = length
    }

    /// Move o cursor `delta` grafemas; sem `extending`, colapsa a seleção (setas esquerda/direita
    /// com seleção ativa vão para a borda correspondente).
    public mutating func moveCaret(by delta: Int, extending: Bool = false) {
        if !extending, hasSelection {
            let target = delta < 0 ? selection.lowerBound : selection.upperBound
            anchor = target
            caret = target
            return
        }
        caret = clamp(caret + delta)
        if !extending { anchor = caret }
    }

    public mutating func moveToStart(extending: Bool = false) { move(to: 0, extending: extending) }
    public mutating func moveToEnd(extending: Bool = false) { move(to: length, extending: extending) }

    /// Move até o início/fim da palavra (espaços são ignorados antes de percorrer a palavra).
    public mutating func moveWord(forward: Bool, extending: Bool = false) {
        let chars = Array(text)
        var i = caret
        if forward {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            while i < chars.count, !chars[i].isWhitespace { i += 1 }
        } else {
            while i > 0, chars[i - 1].isWhitespace { i -= 1 }
            while i > 0, !chars[i - 1].isWhitespace { i -= 1 }
        }
        move(to: i, extending: extending)
    }

    private mutating func move(to target: Int, extending: Bool) {
        caret = clamp(target)
        if !extending { anchor = caret }
    }

    // MARK: Edição

    /// Substitui a seleção por `string` e posiciona o cursor depois dela.
    public mutating func insert(_ string: String) {
        replace(selection, with: string)
    }

    public mutating func deleteBackward() {
        if hasSelection {
            replace(selection, with: "")
        } else if caret > 0 {
            replace((caret - 1)..<caret, with: "")
        }
    }

    public mutating func deleteForward() {
        if hasSelection {
            replace(selection, with: "")
        } else if caret < length {
            replace(caret..<(caret + 1), with: "")
        }
    }

    /// Substitui uma faixa de grafemas e leva o cursor ao fim do texto inserido.
    public mutating func replace(_ range: Range<Int>, with string: String) {
        let lo = clamp(range.lowerBound)
        let hi = max(lo, clamp(range.upperBound))
        var chars = Array(text)
        var insert = Array(string)
        if let limit = maxLength {
            let room = max(0, limit - (chars.count - (hi - lo)))
            if insert.count > room { insert = Array(insert.prefix(room)) }
        }
        chars.replaceSubrange(lo..<hi, with: insert)
        text = String(chars)
        length = chars.count
        caret = lo + insert.count
        anchor = caret
        markedRange = nil
    }

    // MARK: Composição (IME)

    /// Define o texto em composição, substituindo a composição anterior ou a seleção.
    public mutating func setMarkedText(_ string: String) {
        let target = markedRange ?? selection
        replace(target, with: string)
        let start = target.lowerBound
        markedRange = start..<caret
    }

    /// Confirma a composição atual.
    public mutating func commitMarkedText() { markedRange = nil }

    // MARK: Conversão para o layout

    /// Deslocamento em escalares Unicode correspondente a um deslocamento em grafemas.
    public func scalarOffset(forCharacterOffset offset: Int) -> Int {
        text.prefix(clamp(offset)).unicodeScalars.count
    }

    /// Deslocamento em grafemas para um deslocamento em escalares (arredonda para o grafema anterior).
    public func characterOffset(forScalarOffset offset: Int) -> Int {
        var scalars = 0
        var chars = 0
        for c in text {
            let next = scalars + c.unicodeScalars.count
            if next > offset { break }
            scalars = next
            chars += 1
        }
        return chars
    }

    private func clamp(_ v: Int) -> Int { max(0, min(length, v)) }

    private func substring(_ r: Range<Int>) -> String {
        let lo = text.index(text.startIndex, offsetBy: clamp(r.lowerBound))
        let hi = text.index(text.startIndex, offsetBy: clamp(r.upperBound))
        return String(text[lo..<hi])
    }
}

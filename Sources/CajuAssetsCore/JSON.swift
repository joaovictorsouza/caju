/// Valor JSON (RFC 8259) decodificado a partir de bytes UTF-8 sem `Foundation`.
enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var arrayValues: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    var objectPairs: [(String, JSONValue)]? {
        if case .object(let pairs) = self { return pairs }
        return nil
    }

    func field(_ key: String) -> JSONValue? {
        guard case .object(let pairs) = self else { return nil }
        for i in pairs.indices.reversed() where pairs[i].0 == key {
            return pairs[i].1
        }
        return nil
    }

    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        var stack: [(JSONValue, JSONValue)] = [(lhs, rhs)]
        while let (a, b) = stack.popLast() {
            switch (a, b) {
            case (.null, .null):
                continue
            case (.bool(let x), .bool(let y)):
                if x != y { return false }
            case (.number(let x), .number(let y)):
                if x != y { return false }
            case (.string(let x), .string(let y)):
                if x != y { return false }
            case (.array(let xs), .array(let ys)):
                if xs.count != ys.count { return false }
                for i in xs.indices {
                    stack.append((xs[i], ys[i]))
                }
            case (.object(let xs), .object(let ys)):
                if xs.count != ys.count { return false }
                for i in xs.indices {
                    if xs[i].0 != ys[i].0 { return false }
                    stack.append((xs[i].1, ys[i].1))
                }
            default:
                return false
            }
        }
        return true
    }
}

/// Parser JSON iterativo (sem recursão ilimitada) conforme RFC 8259 sobre `[UInt8]` UTF-8.
enum JSONParser {
    static func parse(
        _ bytes: [UInt8],
        limits: AssetLimits = .default,
        context: String = "json"
    ) throws(AssetError) -> JSONValue {
        try checkLimit(bytes.count, limits.maxInputBytes, context)
        return try parseSlice(bytes, range: 0..<bytes.count, limits: limits, context: context)
    }

    static func parseSlice(
        _ bytes: [UInt8],
        range: Range<Int>,
        limits: AssetLimits,
        context: String = "json"
    ) throws(AssetError) -> JSONValue {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else {
            throw .truncated(context: context)
        }
        try checkLimit(range.count, limits.maxInputBytes, context)
        var cursor = Cursor(bytes: bytes, offset: range.lowerBound, end: range.upperBound, limits: limits)
        return try cursor.parseRoot(context: context)
    }
}

private struct Cursor {
    private enum Container {
        case array([JSONValue])
        case object(pairs: [(String, JSONValue)], currentKey: String?)
    }

    private enum State {
        case expectValue
        case expectKey
        case afterValue
    }

    let bytes: [UInt8]
    var offset: Int
    let end: Int
    let limits: AssetLimits

    mutating func parseRoot(context: String) throws(AssetError) -> JSONValue {
        var stack: [Container] = []
        var state: State = .expectValue
        var root: JSONValue?

        loop: while true {
            switch state {
            case .expectValue:
                skipWhitespace()
                guard offset < end else { throw .truncated(context: context) }
                let b = bytes[offset]
                switch b {
                case 0x5B:  // '['
                    try checkLimit(stack.count + 1, limits.maxJSONDepth, context)
                    offset += 1
                    skipWhitespace()
                    guard offset < end else { throw .truncated(context: context) }
                    if bytes[offset] == 0x5D {
                        offset += 1
                        try deliver(.array([]), stack: &stack, root: &root, context: context)
                        state = .afterValue
                    } else {
                        stack.append(.array([]))
                        state = .expectValue
                    }
                case 0x7B:  // '{'
                    try checkLimit(stack.count + 1, limits.maxJSONDepth, context)
                    offset += 1
                    skipWhitespace()
                    guard offset < end else { throw .truncated(context: context) }
                    if bytes[offset] == 0x7D {
                        offset += 1
                        try deliver(.object([]), stack: &stack, root: &root, context: context)
                        state = .afterValue
                    } else {
                        stack.append(.object(pairs: [], currentKey: nil))
                        state = .expectKey
                    }
                case 0x22:  // '"'
                    let s = try parseString(context: context)
                    try deliver(.string(s), stack: &stack, root: &root, context: context)
                    state = .afterValue
                case 0x74:  // 't'
                    try expectLiteral([0x74, 0x72, 0x75, 0x65], context: context)
                    try deliver(.bool(true), stack: &stack, root: &root, context: context)
                    state = .afterValue
                case 0x66:  // 'f'
                    try expectLiteral([0x66, 0x61, 0x6C, 0x73, 0x65], context: context)
                    try deliver(.bool(false), stack: &stack, root: &root, context: context)
                    state = .afterValue
                case 0x6E:  // 'n'
                    try expectLiteral([0x6E, 0x75, 0x6C, 0x6C], context: context)
                    try deliver(.null, stack: &stack, root: &root, context: context)
                    state = .afterValue
                case 0x2D, 0x30...0x39:
                    let n = try parseNumber(context: context)
                    try deliver(.number(n), stack: &stack, root: &root, context: context)
                    state = .afterValue
                default:
                    throw .invalid(context: context, reason: "token JSON inesperado no byte \(offset)")
                }

            case .expectKey:
                skipWhitespace()
                guard offset < end else { throw .truncated(context: context) }
                guard bytes[offset] == 0x22 else {
                    throw .invalid(context: context, reason: "chave string esperada no byte \(offset)")
                }
                let key = try parseString(context: context)
                skipWhitespace()
                guard offset < end else { throw .truncated(context: context) }
                guard bytes[offset] == 0x3A else {
                    throw .invalid(context: context, reason: "':' esperado após chave no byte \(offset)")
                }
                offset += 1
                let topIndex = stack.count - 1
                guard case .object(let pairs, nil) = stack[topIndex] else {
                    throw .invalid(context: context, reason: "estado interno inválido de objeto")
                }
                stack[topIndex] = .object(pairs: pairs, currentKey: key)
                state = .expectValue

            case .afterValue:
                skipWhitespace()
                guard let top = stack.last else {
                    guard offset == end else {
                        throw .invalid(context: context, reason: "dados após o fim do valor JSON")
                    }
                    break loop
                }
                guard offset < end else { throw .truncated(context: context) }
                let b = bytes[offset]
                switch top {
                case .array(let items):
                    if b == 0x2C {  // ','
                        offset += 1
                        state = .expectValue
                    } else if b == 0x5D {  // ']'
                        offset += 1
                        stack.removeLast()
                        try deliver(.array(items), stack: &stack, root: &root, context: context)
                        state = .afterValue
                    } else {
                        throw .invalid(context: context, reason: "',' ou ']' esperado no byte \(offset)")
                    }
                case .object(let pairs, _):
                    if b == 0x2C {  // ','
                        offset += 1
                        state = .expectKey
                    } else if b == 0x7D {  // '}'
                        offset += 1
                        stack.removeLast()
                        try deliver(.object(pairs), stack: &stack, root: &root, context: context)
                        state = .afterValue
                    } else {
                        throw .invalid(context: context, reason: "',' ou '}' esperado no byte \(offset)")
                    }
                }
            }
        }

        guard let value = root else {
            throw .truncated(context: context)
        }
        return value
    }

    private func deliver(
        _ value: JSONValue,
        stack: inout [Container],
        root: inout JSONValue?,
        context: String
    ) throws(AssetError) {
        if stack.isEmpty {
            root = value
            return
        }
        let topIndex = stack.count - 1
        switch stack[topIndex] {
        case .array(var items):
            try checkLimit(items.count + 1, limits.maxElements, context)
            items.append(value)
            stack[topIndex] = .array(items)
        case .object(var pairs, let currentKey):
            guard let key = currentKey else {
                throw .invalid(context: context, reason: "valor sem chave em objeto")
            }
            try checkLimit(pairs.count + 1, limits.maxElements, context)
            pairs.append((key, value))
            stack[topIndex] = .object(pairs: pairs, currentKey: nil)
        }
    }

    private mutating func skipWhitespace() {
        while offset < end {
            switch bytes[offset] {
            case 0x20, 0x09, 0x0A, 0x0D:
                offset += 1
            default:
                return
            }
        }
    }

    private mutating func expectLiteral(_ literal: [UInt8], context: String) throws(AssetError) {
        for expected in literal {
            guard offset < end else { throw .truncated(context: context) }
            guard bytes[offset] == expected else {
                throw .invalid(context: context, reason: "literal JSON inválido no byte \(offset)")
            }
            offset += 1
        }
    }

    private mutating func parseString(context: String) throws(AssetError) -> String {
        offset += 1  // consome '"'
        var utf8: [UInt8] = []
        while offset < end {
            let b = bytes[offset]
            if b == 0x22 {  // '"'
                offset += 1
                return String(decoding: utf8, as: UTF8.self)
            }
            if b == 0x5C {  // '\'
                offset += 1
                try parseEscape(into: &utf8, context: context)
                continue
            }
            if b < 0x20 {
                throw .invalid(context: context, reason: "caractere de controle sem escape no byte \(offset)")
            }
            if b < 0x80 {
                utf8.append(b)
                offset += 1
                continue
            }
            try copyValidatedUTF8Sequence(into: &utf8, context: context)
        }
        throw .truncated(context: context)
    }

    private mutating func parseEscape(into utf8: inout [UInt8], context: String) throws(AssetError) {
        guard offset < end else { throw .truncated(context: context) }
        let esc = bytes[offset]
        offset += 1
        switch esc {
        case 0x22: utf8.append(0x22)  // \"
        case 0x5C: utf8.append(0x5C)  // \\
        case 0x2F: utf8.append(0x2F)  // \/
        case 0x62: utf8.append(0x08)  // \b
        case 0x66: utf8.append(0x0C)  // \f
        case 0x6E: utf8.append(0x0A)  // \n
        case 0x72: utf8.append(0x0D)  // \r
        case 0x74: utf8.append(0x09)  // \t
        case 0x75:  // \uXXXX
            let u1 = try parseHex4(context: context)
            if (0xD800...0xDBFF).contains(u1) {
                guard offset < end else { throw .truncated(context: context) }
                guard bytes[offset] == 0x5C else {
                    throw .invalid(context: context, reason: "high surrogate isolado no byte \(offset)")
                }
                offset += 1
                guard offset < end else { throw .truncated(context: context) }
                guard bytes[offset] == 0x75 else {
                    throw .invalid(context: context, reason: "high surrogate sem \\u subsequente")
                }
                offset += 1
                let u2 = try parseHex4(context: context)
                guard (0xDC00...0xDFFF).contains(u2) else {
                    throw .invalid(context: context, reason: "low surrogate inválido após high surrogate")
                }
                let codePoint: UInt32 = 0x10000 + ((UInt32(u1) - 0xD800) << 10) + (UInt32(u2) - 0xDC00)
                guard let scalar = Unicode.Scalar(codePoint) else {
                    throw .invalid(context: context, reason: "code point Unicode inválido")
                }
                UTF8.encode(scalar) { utf8.append($0) }
            } else if (0xDC00...0xDFFF).contains(u1) {
                throw .invalid(context: context, reason: "low surrogate isolado")
            } else {
                guard let scalar = Unicode.Scalar(UInt32(u1)) else {
                    throw .invalid(context: context, reason: "code point Unicode inválido")
                }
                UTF8.encode(scalar) { utf8.append($0) }
            }
        default:
            throw .invalid(context: context, reason: "escape JSON inválido no byte \(offset - 1)")
        }
    }

    private mutating func parseHex4(context: String) throws(AssetError) -> UInt16 {
        var value: UInt16 = 0
        for _ in 0..<4 {
            guard offset < end else { throw .truncated(context: context) }
            let b = bytes[offset]
            offset += 1
            let nibble: UInt16
            switch b {
            case 0x30...0x39: nibble = UInt16(b - 0x30)
            case 0x41...0x46: nibble = UInt16(b - 0x41 + 10)
            case 0x61...0x66: nibble = UInt16(b - 0x61 + 10)
            default:
                throw .invalid(context: context, reason: "dígito hexadecimal inválido em \\uXXXX")
            }
            value = (value << 4) | nibble
        }
        return value
    }

    private mutating func copyValidatedUTF8Sequence(
        into utf8: inout [UInt8],
        context: String
    ) throws(AssetError) {
        let b0 = bytes[offset]
        switch b0 {
        case 0xC2...0xDF:
            guard offset + 1 < end else { throw .truncated(context: context) }
            let b1 = bytes[offset + 1]
            guard (0x80...0xBF).contains(b1) else {
                throw .invalid(context: context, reason: "UTF-8 inválido no byte \(offset)")
            }
            utf8.append(b0)
            utf8.append(b1)
            offset += 2

        case 0xE0...0xEF:
            guard offset + 2 < end else { throw .truncated(context: context) }
            let b1 = bytes[offset + 1]
            let b2 = bytes[offset + 2]
            let validB1: Bool =
                switch b0 {
                case 0xE0: (0xA0...0xBF).contains(b1)
                case 0xED: (0x80...0x9F).contains(b1)
                default: (0x80...0xBF).contains(b1)
                }
            guard validB1, (0x80...0xBF).contains(b2) else {
                throw .invalid(context: context, reason: "UTF-8 inválido no byte \(offset)")
            }
            utf8.append(b0)
            utf8.append(b1)
            utf8.append(b2)
            offset += 3

        case 0xF0...0xF4:
            guard offset + 3 < end else { throw .truncated(context: context) }
            let b1 = bytes[offset + 1]
            let b2 = bytes[offset + 2]
            let b3 = bytes[offset + 3]
            let validB1: Bool =
                switch b0 {
                case 0xF0: (0x90...0xBF).contains(b1)
                case 0xF4: (0x80...0x8F).contains(b1)
                default: (0x80...0xBF).contains(b1)
                }
            guard validB1, (0x80...0xBF).contains(b2), (0x80...0xBF).contains(b3) else {
                throw .invalid(context: context, reason: "UTF-8 inválido no byte \(offset)")
            }
            utf8.append(b0)
            utf8.append(b1)
            utf8.append(b2)
            utf8.append(b3)
            offset += 4

        default:
            throw .invalid(context: context, reason: "UTF-8 inválido no byte \(offset)")
        }
    }

    private mutating func parseNumber(context: String) throws(AssetError) -> Double {
        let start = offset
        var negative = false
        if bytes[offset] == 0x2D {  // '-'
            negative = true
            offset += 1
        }

        guard offset < end else { throw .truncated(context: context) }
        let firstDigit = bytes[offset]
        guard (0x30...0x39).contains(firstDigit) else {
            throw .invalid(context: context, reason: "dígito esperado em número no byte \(offset)")
        }

        var intAccum: UInt64 = 0
        var intDigits = 0
        if firstDigit == 0x30 {
            offset += 1
            intDigits = 1
            if offset < end, (0x30...0x39).contains(bytes[offset]) {
                throw .invalid(context: context, reason: "zero à esquerda ilegal em número")
            }
        } else {
            while offset < end, (0x30...0x39).contains(bytes[offset]) {
                if intDigits < 15 {
                    intAccum = intAccum * 10 + UInt64(bytes[offset] - 0x30)
                }
                intDigits += 1
                offset += 1
            }
        }

        var hasFrac = false
        if offset < end, bytes[offset] == 0x2E {  // '.'
            hasFrac = true
            offset += 1
            guard offset < end else { throw .truncated(context: context) }
            guard (0x30...0x39).contains(bytes[offset]) else {
                throw .invalid(context: context, reason: "dígito esperado após '.' no byte \(offset)")
            }
            while offset < end, (0x30...0x39).contains(bytes[offset]) {
                offset += 1
            }
        }

        var hasExp = false
        if offset < end, bytes[offset] == 0x65 || bytes[offset] == 0x45 {  // 'e' / 'E'
            hasExp = true
            offset += 1
            if offset < end, bytes[offset] == 0x2B || bytes[offset] == 0x2D {  // '+' / '-'
                offset += 1
            }
            guard offset < end else { throw .truncated(context: context) }
            guard (0x30...0x39).contains(bytes[offset]) else {
                throw .invalid(context: context, reason: "dígito esperado em expoente no byte \(offset)")
            }
            while offset < end, (0x30...0x39).contains(bytes[offset]) {
                offset += 1
            }
        }

        if !hasFrac, !hasExp, intDigits <= 15 {
            let value = Double(intAccum)
            return negative ? -value : value
        }

        let text = String(decoding: bytes[start..<offset], as: UTF8.self)
        guard let parsed = Double(text), parsed.isFinite else {
            throw .invalid(context: context, reason: "número fora da faixa finita de Double")
        }
        return parsed
    }
}

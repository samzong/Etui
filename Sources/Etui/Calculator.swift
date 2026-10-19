import Foundation

enum Calculator {
    static func result(_ query: String) -> String? {
        let text = query.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !text.isEmpty, text.allSatisfy({
            (48 ... 57).contains($0.value) || ".+-*/()".unicodeScalars.contains($0)
        }) else { return nil }
        var parser = Parser(bytes: Array(String(text).utf8))
        guard let value = parser.expression(), parser.index == parser.bytes.count,
              parser.hasBinaryOperator, value.isFinite else { return nil }
        if value.rounded() == value, abs(value) <= 9_007_199_254_740_992 {
            return String(Int64(value))
        }
        return String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func entry(_ query: String) -> Entry? {
        guard let result = result(query) else { return nil }
        return Entry(id: "internal.calculator", name: "= \(result)", aliases: [], path: "", kind: .calculation(result))
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var hasBinaryOperator = false
        var depth = 0

        mutating func expression() -> Double? {
            guard var value = product() else { return nil }
            while index < bytes.count, bytes[index] == 43 || bytes[index] == 45 {
                let operation = bytes[index]
                index += 1
                hasBinaryOperator = true
                guard let rhs = product() else { return nil }
                value = operation == 43 ? value + rhs : value - rhs
                guard value.isFinite else { return nil }
            }
            return value
        }

        mutating func product() -> Double? {
            guard var value = operand() else { return nil }
            while index < bytes.count, bytes[index] == 42 || bytes[index] == 47 {
                let operation = bytes[index]
                index += 1
                hasBinaryOperator = true
                guard let rhs = operand(), operation != 47 || rhs != 0 else { return nil }
                value = operation == 42 ? value * rhs : value / rhs
                guard value.isFinite else { return nil }
            }
            return value
        }

        mutating func operand() -> Double? {
            var negative = false
            while consume(45) {
                negative.toggle()
            }
            let value: Double
            if consume(40) {
                guard depth < 128 else { return nil }
                depth += 1
                guard let nested = expression(), consume(41) else { return nil }
                depth -= 1
                value = nested
            } else {
                let start = index
                var digits = 0
                while index < bytes.count, (48 ... 57).contains(bytes[index]) {
                    index += 1
                    digits += 1
                }
                if consume(46) {
                    while index < bytes.count, (48 ... 57).contains(bytes[index]) {
                        index += 1
                        digits += 1
                    }
                }
                guard digits > 0, let number = Double(String(decoding: bytes[start ..< index], as: UTF8.self)),
                      number.isFinite else { return nil }
                value = number
            }
            return negative ? -value : value
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }
    }
}

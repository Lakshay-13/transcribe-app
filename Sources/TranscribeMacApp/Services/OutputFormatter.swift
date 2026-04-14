import Foundation

struct OutputFormatter: Sendable {
    static func apply(style: OutputStyle, to text: String) -> String {
        switch style {
        case .original:
            return text
        case .romanized:
            return romanize(text)
        case .hinglish:
            return hinglish(text)
        }
    }

    private static func romanize(_ input: String) -> String {
        let latin = (input as NSString).applyingTransform(.toLatin, reverse: false) ?? input
        let stripped = (latin as NSString).applyingTransform(.stripCombiningMarks, reverse: false) ?? latin
        return stripped
    }

    private static func hinglish(_ input: String) -> String {
        var result = ""
        var devanagariBuffer = ""

        func flushBuffer() {
            guard !devanagariBuffer.isEmpty else { return }
            result += romanize(devanagariBuffer)
            devanagariBuffer = ""
        }

        for scalar in input.unicodeScalars {
            if isDevanagari(scalar) {
                devanagariBuffer.append(Character(scalar))
            } else {
                flushBuffer()
                result.append(Character(scalar))
            }
        }

        flushBuffer()
        return result
    }

    private static func isDevanagari(_ scalar: UnicodeScalar) -> Bool {
        (0x0900...0x097F).contains(scalar.value)
    }
}

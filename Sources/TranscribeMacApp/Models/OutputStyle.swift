import Foundation

enum OutputStyle: String, CaseIterable, Identifiable, Sendable {
    case original
    case romanized
    case hinglish

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original:
            return "Original"
        case .romanized:
            return "Romanized"
        case .hinglish:
            return "Hinglish"
        }
    }
}

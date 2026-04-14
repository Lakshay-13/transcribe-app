import Foundation

enum WhisperProfile: String, CaseIterable, Identifiable, Sendable {
    case light
    case medium
    case large

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light:
            return "Light"
        case .medium:
            return "Medium"
        case .large:
            return "Large"
        }
    }

    var defaultModelID: String {
        switch self {
        case .light:
            return "base"
        case .medium:
            return "small"
        case .large:
            return "large-v3"
        }
    }
}

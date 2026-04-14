import Foundation

enum TranscriptionMode: String, CaseIterable, Identifiable, Sendable {
    case local
    case api

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local:
            return "Local"
        case .api:
            return "API"
        }
    }
}

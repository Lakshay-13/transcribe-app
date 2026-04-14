import Foundation

struct TranscriptHistoryItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var content: String
    var isPartial: Bool

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        content: String,
        isPartial: Bool
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.content = content
        self.isPartial = isPartial
    }
}

import Foundation

enum TranscriptSessionStatus: String, Codable, Hashable, Sendable {
    case running
    case completed
    case cancelled
    case failed

    var isTerminal: Bool {
        switch self {
        case .running:
            return false
        case .completed, .cancelled, .failed:
            return true
        }
    }
}

struct TranscriptHistoryItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var content: String
    var isPartial: Bool
    var sessionStatus: TranscriptSessionStatus
    var sourceFileName: String
    var failureMessage: String?

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        content: String,
        isPartial: Bool,
        sessionStatus: TranscriptSessionStatus? = nil,
        sourceFileName: String = "No file selected",
        failureMessage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.content = content
        self.isPartial = isPartial
        self.sessionStatus = sessionStatus ?? (isPartial ? .cancelled : .completed)
        self.sourceFileName = sourceFileName
        self.failureMessage = failureMessage
    }
}

extension TranscriptHistoryItem {
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt
        case updatedAt
        case content
        case isPartial
        case sessionStatus
        case sourceFileName
        case failureMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let now = Date()

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Transcript"
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        sourceFileName = try container.decodeIfPresent(String.self, forKey: .sourceFileName) ?? "No file selected"
        failureMessage = try container.decodeIfPresent(String.self, forKey: .failureMessage)

        let decodedStatus = try container.decodeIfPresent(TranscriptSessionStatus.self, forKey: .sessionStatus)
        let legacyPartial = try container.decodeIfPresent(Bool.self, forKey: .isPartial) ?? false
        sessionStatus = decodedStatus ?? (legacyPartial ? .cancelled : .completed)
        isPartial = sessionStatus != .completed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(content, forKey: .content)
        try container.encode(isPartial, forKey: .isPartial)
        try container.encode(sessionStatus, forKey: .sessionStatus)
        try container.encode(sourceFileName, forKey: .sourceFileName)
        try container.encodeIfPresent(failureMessage, forKey: .failureMessage)
    }
}

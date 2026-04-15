import Foundation

struct TranscriptHistoryStore: Sendable {
    func load() -> [TranscriptHistoryItem] {
        guard let data = try? Data(contentsOf: storageURL) else {
            return []
        }

        for decoder in decodeAttempts {
            do {
                let items = try decoder.decode([TranscriptHistoryItem].self, from: data)
                return items.sorted { $0.updatedAt > $1.updatedAt }
            } catch {
                continue
            }
        }

        return []
    }

    func save(_ items: [TranscriptHistoryItem]) {
        let sorted = items.sorted { $0.updatedAt > $1.updatedAt }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(sorted)

            let folder = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            // Best-effort persistence; failures should not crash transcription flow.
        }
    }

    private var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return appSupport
            .appendingPathComponent("TranscribeMacApp", isDirectory: true)
            .appendingPathComponent("transcript-history.json")
    }

    private var decodeAttempts: [JSONDecoder] {
        let primary = JSONDecoder()
        primary.dateDecodingStrategy = .iso8601

        let fallback = JSONDecoder()
        fallback.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let isoString = try? container.decode(String.self),
               let parsed = Self.parseISO8601Date(isoString) {
                return parsed
            }

            if let numeric = try? container.decode(Double.self) {
                if numeric > 978_307_200 { // 2001-01-01 as UNIX timestamp.
                    return Date(timeIntervalSince1970: numeric)
                }
                return Date(timeIntervalSinceReferenceDate: numeric)
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported date encoding in transcript history."
            )
        }

        return [primary, fallback, JSONDecoder()]
    }

    static func parseISO8601Date(_ raw: String) -> Date? {
        let formatterWithFractional = ISO8601DateFormatter()
        formatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatterWithFractional.date(from: raw) {
            return value
        }
        return ISO8601DateFormatter().date(from: raw)
    }
}

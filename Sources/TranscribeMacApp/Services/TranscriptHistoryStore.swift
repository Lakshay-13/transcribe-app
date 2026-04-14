import Foundation

struct TranscriptHistoryStore: Sendable {
    func load() -> [TranscriptHistoryItem] {
        guard let data = try? Data(contentsOf: storageURL) else {
            return []
        }

        do {
            let items = try JSONDecoder().decode([TranscriptHistoryItem].self, from: data)
            return items.sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            return []
        }
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
}

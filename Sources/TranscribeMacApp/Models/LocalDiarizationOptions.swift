import Foundation

struct LocalDiarizationOptions: Sendable {
    let isEnabled: Bool
    let huggingFaceToken: String?
    let expectedSpeakerCount: Int?
    let chunkDurationSeconds: Int

    static let defaultChunkDurationSeconds = 60

    static let disabled = LocalDiarizationOptions(
        isEnabled: false,
        huggingFaceToken: nil,
        expectedSpeakerCount: nil,
        chunkDurationSeconds: defaultChunkDurationSeconds
    )
}

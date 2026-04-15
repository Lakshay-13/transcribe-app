import Foundation

struct PreparedMedia: Sendable {
    let fileURL: URL
    let temporaryDirectory: URL?

    func cleanup() {
        guard let temporaryDirectory else { return }
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

struct MediaPreparationService: Sendable {
    private let runner = ProcessRunner()
    private let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "webm"]

    func prepare(fileURL: URL) throws -> PreparedMedia {
        let ext = fileURL.pathExtension.lowercased()
        guard videoExtensions.contains(ext) else {
            return PreparedMedia(fileURL: fileURL, temporaryDirectory: nil)
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscribeMacApp-MediaPrep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let outputURL = tempDir.appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("m4a")

        let runtimeToolchain = RuntimeToolchain()
        let ffmpegArguments = [
            "-nostdin",
            "-y",
            "-i", fileURL.path,
            "-vn",
            "-acodec", "aac",
            "-b:a", "192k",
            outputURL.path
        ]

        let invocation = runtimeToolchain.ffmpegInvocation
        let result = try runner.run(
            executablePath: invocation.executablePath,
            arguments: invocation.argumentsPrefix + ffmpegArguments,
            environment: runtimeToolchain.environmentOverrides
        )

        guard result.exitCode == 0 else {
            if runtimeToolchain.ffmpegIsLikelyMissing(in: result) {
                throw TranscriptionError.commandFailed(
                    command: "ffmpeg",
                    exitCode: result.exitCode,
                    message: runtimeToolchain.ffmpegMissingMessage()
                )
            }

            throw TranscriptionError.commandFailed(
                command: "ffmpeg",
                exitCode: result.exitCode,
                message: normalizedError(from: result)
            )
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw TranscriptionError.outputNotFound("Video conversion finished but no audio file was produced.")
        }

        return PreparedMedia(fileURL: outputURL, temporaryDirectory: tempDir)
    }

    private func normalizedError(from output: ProcessOutput) -> String {
        let text = output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}

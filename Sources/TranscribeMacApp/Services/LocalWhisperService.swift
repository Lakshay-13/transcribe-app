import Foundation

struct LocalWhisperService: Sendable {
    private let runner = ProcessRunner()

    func transcribe(
        fileURL: URL,
        model: String,
        languageCode: String?,
        diarization: LocalDiarizationOptions = .disabled,
        enableStreaming: Bool = false,
        progress: (@Sendable (Double) -> Void)? = nil,
        partialTranscript: (@Sendable (String) -> Void)? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> String {
        let runtimeToolchain = RuntimeToolchain()

        if diarization.isEnabled {
            return try transcribeWithWhisperX(
                fileURL: fileURL,
                model: model,
                languageCode: languageCode,
                diarization: diarization,
                runtimeToolchain: runtimeToolchain,
                enableStreaming: enableStreaming,
                progress: progress,
                partialTranscript: partialTranscript,
                isCancelled: isCancelled
            )
        }

        return try transcribeWithWhisper(
            fileURL: fileURL,
            model: model,
            languageCode: languageCode,
            runtimeToolchain: runtimeToolchain,
            enableStreaming: enableStreaming,
            progress: progress,
            partialTranscript: partialTranscript,
            isCancelled: isCancelled
        )
    }

    private func transcribeWithWhisper(
        fileURL: URL,
        model: String,
        languageCode: String?,
        runtimeToolchain: RuntimeToolchain,
        enableStreaming: Bool,
        progress: (@Sendable (Double) -> Void)?,
        partialTranscript: (@Sendable (String) -> Void)?,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> String {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscribeMacApp-WhisperOut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let pythonInvocation = runtimeToolchain.pythonInvocation
        let whisperCommand = commandDescription(for: pythonInvocation, module: "whisper")
        var arguments = pythonInvocation.argumentsPrefix + [
            "-m", "whisper",
            fileURL.path,
            "--model", model,
            "--task", "transcribe",
            "--output_format", "txt",
            "--output_dir", outputDir.path,
            "--fp16", "False",
            "--verbose", enableStreaming ? "True" : "False"
        ]

        if let languageCode {
            arguments += ["--language", languageCode]
        }

        let progressRelay = TQDMProgressRelay(callback: progress)
        let segmentRelay = SegmentTranscriptRelay(callback: partialTranscript)

        let result = try runner.run(
            executablePath: pythonInvocation.executablePath,
            arguments: arguments,
            environment: runtimeToolchain.environmentOverrides,
            onStandardOutput: {
                progressRelay.consume($0)
                segmentRelay.consume($0)
            },
            onStandardError: {
                progressRelay.consume($0)
                segmentRelay.consume($0)
            },
            isCancelled: isCancelled
        )

        guard result.exitCode == 0 else {
            let stderr = result.standardError.lowercased()
            if stderr.contains("no module named whisper") {
                throw TranscriptionError.commandFailed(
                    command: whisperCommand,
                    exitCode: result.exitCode,
                    message: missingWhisperMessage(pythonInvocation: pythonInvocation)
                )
            }

            if runtimeToolchain.ffmpegIsLikelyMissing(in: result) {
                throw TranscriptionError.commandFailed(
                    command: whisperCommand,
                    exitCode: result.exitCode,
                    message: runtimeToolchain.ffmpegMissingMessage()
                )
            }

            throw TranscriptionError.commandFailed(
                command: whisperCommand,
                exitCode: result.exitCode,
                message: normalizedError(from: result)
            )
        }

        guard let transcriptFile = try firstTranscriptFile(in: outputDir) else {
            throw TranscriptionError.outputNotFound("Whisper completed but did not generate a transcript file.")
        }

        let text = try String(contentsOf: transcriptFile, encoding: .utf8)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranscriptionError.outputNotFound("Whisper produced an empty transcript.")
        }

        partialTranscript?(trimmed)
        return trimmed
    }

    private func transcribeWithWhisperX(
        fileURL: URL,
        model: String,
        languageCode: String?,
        diarization: LocalDiarizationOptions,
        runtimeToolchain: RuntimeToolchain,
        enableStreaming: Bool,
        progress: (@Sendable (Double) -> Void)?,
        partialTranscript: (@Sendable (String) -> Void)?,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> String {
        let hfToken = diarization.huggingFaceToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hfToken, !hfToken.isEmpty else {
            throw TranscriptionError.validation("Speaker separation needs a Hugging Face token. Add it in Settings.")
        }

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscribeMacApp-WhisperXOut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let pythonInvocation = runtimeToolchain.pythonInvocation
        let whisperXCommand = commandDescription(for: pythonInvocation, module: "whisperx")
        var arguments = pythonInvocation.argumentsPrefix + [
            "-m", "whisperx",
            fileURL.path,
            "--model", model,
            "--task", "transcribe",
            "--output_format", "json",
            "--output_dir", outputDir.path,
            "--chunk_size", "\(diarization.chunkDurationSeconds)",
            "--verbose", enableStreaming ? "True" : "False",
            "--diarize",
            "--hf_token", hfToken
        ]

        if let languageCode {
            arguments += ["--language", languageCode]
        }

        if let expectedSpeakerCount = diarization.expectedSpeakerCount {
            arguments += ["--min_speakers", "\(expectedSpeakerCount)", "--max_speakers", "\(expectedSpeakerCount)"]
        }

        let progressRelay = TQDMProgressRelay(callback: progress)
        let segmentRelay = SegmentTranscriptRelay(callback: partialTranscript)
        let result = try runner.run(
            executablePath: pythonInvocation.executablePath,
            arguments: arguments,
            environment: runtimeToolchain.environmentOverrides,
            onStandardOutput: {
                progressRelay.consume($0)
                segmentRelay.consume($0)
            },
            onStandardError: {
                progressRelay.consume($0)
                segmentRelay.consume($0)
            },
            isCancelled: isCancelled
        )

        guard result.exitCode == 0 else {
            let combined = "\(result.standardError)\n\(result.standardOutput)".lowercased()
            if combined.contains("no module named whisperx") {
                throw TranscriptionError.commandFailed(
                    command: whisperXCommand,
                    exitCode: result.exitCode,
                    message: "WhisperX is not installed. Install with: pip install whisperx"
                )
            }
            if combined.contains("huggingface") && combined.contains("token") {
                throw TranscriptionError.commandFailed(
                    command: whisperXCommand,
                    exitCode: result.exitCode,
                    message: "Diarization failed due to Hugging Face token auth. Verify token access for pyannote models."
                )
            }

            if runtimeToolchain.ffmpegIsLikelyMissing(in: result) {
                throw TranscriptionError.commandFailed(
                    command: whisperXCommand,
                    exitCode: result.exitCode,
                    message: runtimeToolchain.ffmpegMissingMessage()
                )
            }

            throw TranscriptionError.commandFailed(
                command: whisperXCommand,
                exitCode: result.exitCode,
                message: normalizedError(from: result)
            )
        }

        guard let jsonFile = try firstJSONTranscriptFile(in: outputDir) else {
            throw TranscriptionError.outputNotFound("WhisperX completed but did not generate a JSON transcript.")
        }

        let transcript = try parseWhisperXOutput(from: jsonFile)
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranscriptionError.outputNotFound("WhisperX produced an empty transcript.")
        }

        partialTranscript?(trimmed)
        return trimmed
    }

    private func firstTranscriptFile(in outputDir: URL) throws -> URL? {
        let files = try FileManager.default.contentsOfDirectory(
            at: outputDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return files
            .filter { $0.pathExtension.lowercased() == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    private func firstJSONTranscriptFile(in outputDir: URL) throws -> URL? {
        let files = try FileManager.default.contentsOfDirectory(
            at: outputDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    private func parseWhisperXOutput(from jsonFile: URL) throws -> String {
        let data = try Data(contentsOf: jsonFile)
        let output = try JSONDecoder().decode(WhisperXOutput.self, from: data)

        if let grouped = groupedTranscriptFromSpeakerSegments(output.segments), !grouped.isEmpty {
            return grouped
        }

        if let text = output.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }

        throw TranscriptionError.outputNotFound("WhisperX JSON output did not include transcript content.")
    }

    private func groupedTranscriptFromSpeakerSegments(_ segments: [WhisperXSegment]?) -> String? {
        guard let segments, !segments.isEmpty else {
            return nil
        }

        let cleaned = segments.compactMap { segment -> (speaker: String?, text: String)? in
            guard let text = segment.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }

            let speaker = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (speaker?.isEmpty == true ? nil : speaker, text)
        }

        guard !cleaned.isEmpty else {
            return nil
        }

        let hasSpeakerLabels = cleaned.contains { $0.speaker != nil }
        guard hasSpeakerLabels else {
            return cleaned.map(\.text).joined(separator: "\n")
        }

        var speakerMap: [String: String] = [:]
        var nextSpeakerNumber = 1
        var grouped: [(speaker: String, text: String)] = []

        for line in cleaned {
            let speakerLabel: String
            if let rawSpeaker = line.speaker {
                if let existing = speakerMap[rawSpeaker] {
                    speakerLabel = existing
                } else {
                    let mapped = "Speaker \(nextSpeakerNumber)"
                    speakerMap[rawSpeaker] = mapped
                    nextSpeakerNumber += 1
                    speakerLabel = mapped
                }
            } else {
                speakerLabel = "Speaker"
            }

            if var last = grouped.last, last.speaker == speakerLabel {
                last.text += " \(line.text)"
                grouped[grouped.count - 1] = last
            } else {
                grouped.append((speaker: speakerLabel, text: line.text))
            }
        }

        return grouped
            .map { "\($0.speaker): \($0.text)" }
            .joined(separator: "\n\n")
    }

    private func commandDescription(for pythonInvocation: RuntimeToolchain.ProcessInvocation, module: String) -> String {
        "\(pythonExecutableDisplayName(for: pythonInvocation)) -m \(module)"
    }

    private func missingWhisperMessage(pythonInvocation: RuntimeToolchain.ProcessInvocation) -> String {
        """
        Whisper is not installed. Re-run the Transcribe installer; its pkg postinstall can provision Whisper in /Library/Application Support/Transcribe/venv. Manual fallback: \(pythonExecutableDisplayName(for: pythonInvocation)) -m pip install -U openai-whisper
        """
    }

    private func pythonExecutableDisplayName(for pythonInvocation: RuntimeToolchain.ProcessInvocation) -> String {
        if pythonInvocation.executablePath == "/usr/bin/env", pythonInvocation.argumentsPrefix == ["python3"] {
            return "python3"
        }

        return ([shellEscapedToken(pythonInvocation.executablePath)] + pythonInvocation.argumentsPrefix.map(shellEscapedToken))
            .joined(separator: " ")
    }

    private func shellEscapedToken(_ token: String) -> String {
        let requiresEscaping = token.contains { character in
            character == " " || character == "'" || character == "\""
        }
        guard requiresEscaping else {
            return token
        }

        let escaped = token.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private func normalizedError(from output: ProcessOutput) -> String {
        let stderr = output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty {
            return stderr
        }

        let stdout = output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty {
            return stdout
        }

        return "Unknown local transcription error."
    }
}

private final class TQDMProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: String = ""
    private var lastFraction: Double = 0
    private let callback: (@Sendable (Double) -> Void)?
    private static let progressRegex = try! NSRegularExpression(pattern: #"(?:^|[\r\n ])(\d{1,3})%\|"#)

    init(callback: (@Sendable (Double) -> Void)?) {
        self.callback = callback
    }

    func consume(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        guard let callback else { return }

        var report: Double?
        lock.lock()
        buffer.append(chunk)
        if buffer.count > 12000 {
            buffer = String(buffer.suffix(6000))
        }

        if let parsed = Self.latestFraction(in: buffer), parsed > lastFraction {
            lastFraction = parsed
            report = parsed
        }
        lock.unlock()

        if let report {
            callback(report)
        }
    }

    private static func latestFraction(in text: String) -> Double? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = progressRegex.matches(in: text, range: range)
        guard let latest = matches.last, latest.numberOfRanges > 1 else {
            return nil
        }
        guard let percentRange = Range(latest.range(at: 1), in: text),
              let percent = Double(text[percentRange])
        else {
            return nil
        }

        let clampedPercent = min(100, max(0, percent))
        return clampedPercent / 100.0
    }
}

private final class SegmentTranscriptRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let callback: (@Sendable (String) -> Void)?
    private var pendingLine = ""
    private var orderedKeys: [String] = []
    private var segmentsByRange: [String: String] = [:]

    private static let segmentRegex = try? NSRegularExpression(
        pattern: #"^\[(\d{2}:\d{2}\.\d{3}\s*-->\s*\d{2}:\d{2}\.\d{3})\]\s*(.+)$"#
    )
    private static let ansiRegex = try? NSRegularExpression(
        pattern: "\u{001B}\\[[0-9;]*[ -/]*[@-~]"
    )

    init(callback: (@Sendable (String) -> Void)?) {
        self.callback = callback
    }

    func consume(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        guard let callback else { return }

        var transcriptToEmit: String?
        lock.lock()

        pendingLine.append(chunk.replacingOccurrences(of: "\r", with: "\n"))
        let parts = pendingLine.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        if pendingLine.hasSuffix("\n") {
            pendingLine = ""
        } else if let last = parts.last {
            pendingLine = last
        }

        let completeLines = pendingLine.isEmpty ? parts : Array(parts.dropLast())
        var didChange = false

        for rawLine in completeLines {
            let line = Self.cleaned(line: rawLine)
            guard let parsed = Self.parseSegment(line: line) else { continue }

            if segmentsByRange[parsed.range] != parsed.text {
                if segmentsByRange[parsed.range] == nil {
                    orderedKeys.append(parsed.range)
                }
                segmentsByRange[parsed.range] = parsed.text
                didChange = true
            }
        }

        if didChange {
            transcriptToEmit = orderedKeys.compactMap { segmentsByRange[$0] }.joined(separator: "\n")
        }

        lock.unlock()

        if let transcriptToEmit, !transcriptToEmit.isEmpty {
            callback(transcriptToEmit)
        }
    }

    private static func cleaned(line: String) -> String {
        guard let ansiRegex else {
            return line.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return ansiRegex
            .stringByReplacingMatches(in: line, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseSegment(line: String) -> (range: String, text: String)? {
        guard let segmentRegex else {
            return nil
        }

        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = segmentRegex.firstMatch(in: line, range: range), match.numberOfRanges > 2,
              let timeRange = Range(match.range(at: 1), in: line),
              let textRange = Range(match.range(at: 2), in: line)
        else {
            return nil
        }

        let text = String(line[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }

        return (String(line[timeRange]), text)
    }
}

private struct WhisperXOutput: Decodable {
    let text: String?
    let segments: [WhisperXSegment]?
}

private struct WhisperXSegment: Decodable {
    let text: String?
    let speaker: String?

    private enum CodingKeys: String, CodingKey {
        case text
        case speaker
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text)

        if let stringSpeaker = try container.decodeIfPresent(String.self, forKey: .speaker) {
            speaker = stringSpeaker
        } else if let intSpeaker = try container.decodeIfPresent(Int.self, forKey: .speaker) {
            speaker = String(intSpeaker)
        } else {
            speaker = nil
        }
    }
}

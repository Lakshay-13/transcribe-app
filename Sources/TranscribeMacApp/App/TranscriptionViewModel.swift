import Foundation

@MainActor
final class TranscriptionViewModel: ObservableObject {
    @Published var selectedMode: TranscriptionMode = .local
    @Published var selectedFileURL: URL?
    @Published var selectedFileName: String = "No file selected"
    @Published var apiKey: String = ""
    @Published var apiModel: String = "whisper-1"
    @Published var apiBaseURLOverride: String = ""
    @Published var selectedProfile: WhisperProfile
    @Published var customLocalModel: String = ""
    @Published var enableSpeakerDiarization: Bool = true
    @Published var enableStreamingTranscript: Bool = true
    @Published var huggingFaceToken: String = ""
    @Published var expectedSpeakerCount: String = ""
    @Published var localChunkDurationSeconds: String = "\(LocalDiarizationOptions.defaultChunkDurationSeconds)"
    @Published var selectedLanguage: WhisperLanguage = .auto
    @Published var outputStyle: OutputStyle = .original
    @Published var transcript: String = ""
    @Published var isTranscribing: Bool = false
    @Published var progress: Double = 0
    @Published var statusMessage: String = "Pick an audio or video file to begin."
    @Published var errorMessage: String?
    @Published var historyItems: [TranscriptHistoryItem] = []
    @Published var selectedHistoryID: UUID?

    let detectedRAMGB: Double
    let recommendedProfile: WhisperProfile

    private let historyStore = TranscriptHistoryStore()
    private var copiedInputURL: URL?
    private var apiProgressTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var shouldSavePartialOnStop: Bool = false

    init() {
        let ram = RAMAdvisor.detectPhysicalRAMGB()
        detectedRAMGB = ram
        recommendedProfile = RAMAdvisor.recommendedProfile(forRAMGB: ram)
        selectedProfile = recommendedProfile

        historyItems = historyStore.load()
        selectedHistoryID = historyItems.first?.id
    }

    deinit {
        apiProgressTask?.cancel()
        transcriptionTask?.cancel()
    }

    var ramRecommendationText: String {
        "Detected \(Int(detectedRAMGB.rounded())) GB RAM. Recommended profile: \(recommendedProfile.displayName) (\(recommendedProfile.defaultModelID))."
    }

    var effectiveLocalModel: String {
        customLocalModel.trimmedOrNil ?? selectedProfile.defaultModelID
    }

    var effectiveAPIModel: String {
        apiModel.trimmedOrNil ?? "whisper-1"
    }

    var suggestedExportBaseName: String {
        selectedFileURL?.deletingPathExtension().lastPathComponent ?? "transcript"
    }

    var selectedHistoryItem: TranscriptHistoryItem? {
        guard let selectedHistoryID else { return nil }
        return historyItems.first { $0.id == selectedHistoryID }
    }

    var activeDisplayTranscript: String {
        selectedHistoryItem?.content ?? transcript
    }

    var localDiarizationOptions: LocalDiarizationOptions {
        let token = huggingFaceToken.trimmedOrNil
        return LocalDiarizationOptions(
            isEnabled: enableSpeakerDiarization && token != nil,
            huggingFaceToken: token,
            expectedSpeakerCount: parsedSpeakerCount,
            chunkDurationSeconds: effectiveLocalChunkDurationSeconds
        )
    }

    var currentSettingsSummary: String {
        switch selectedMode {
        case .local:
            let diarization = enableSpeakerDiarization ? "Speaker Separation On" : "Speaker Separation Off"
            let streaming = enableStreamingTranscript ? "Streaming On" : "Streaming Off"
            return "Local · \(effectiveLocalModel) · \(selectedLanguage.displayName) · \(outputStyle.displayName) · \(streaming) · \(diarization) · \(effectiveLocalChunkDurationSeconds)s"
        case .api:
            return "API · \(effectiveAPIModel) · \(selectedLanguage.displayName) · \(outputStyle.displayName)"
        }
    }

    var chunkDurationValidationMessage: String? {
        let trimmed = localChunkDurationSeconds.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, parsedChunkDurationSeconds == nil else {
            return nil
        }
        return "Invalid chunk duration. Using \(LocalDiarizationOptions.defaultChunkDurationSeconds)s."
    }

    func selectFile(url: URL) {
        do {
            if let previousFile = copiedInputURL {
                try? FileManager.default.removeItem(at: previousFile)
            }

            let localCopy = try makeLocalCopy(of: url)
            copiedInputURL = localCopy
            selectedFileURL = localCopy
            selectedFileName = url.lastPathComponent
            statusMessage = "File ready: \(url.lastPathComponent)"
            errorMessage = nil
            progress = 0
        } catch {
            errorMessage = "Could not import file: \(error.localizedDescription)"
            statusMessage = "Import failed."
            progress = 0
        }
    }

    func setImporterError(_ error: Error) {
        errorMessage = "File picker error: \(error.localizedDescription)"
        statusMessage = "Import failed."
    }

    func clearSelection() {
        if let previousFile = copiedInputURL {
            try? FileManager.default.removeItem(at: previousFile)
        }
        copiedInputURL = nil
        selectedFileURL = nil
        selectedFileName = "No file selected"
        transcript = ""
        selectedHistoryID = nil
        statusMessage = "Pick an audio or video file to begin."
        errorMessage = nil
        progress = 0
    }

    func selectHistoryItem(_ id: UUID) {
        selectedHistoryID = id
        errorMessage = nil
        progress = 0
        statusMessage = "Showing saved transcript."
    }

    func renameHistoryItem(id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = historyItems.firstIndex(where: { $0.id == id }) else {
            return
        }

        historyItems[idx].title = trimmed
        historyItems[idx].updatedAt = Date()
        sortAndPersistHistory()
    }

    func deleteHistoryItem(_ id: UUID) {
        historyItems.removeAll { $0.id == id }
        if selectedHistoryID == id {
            selectedHistoryID = historyItems.first?.id
        }
        sortAndPersistHistory()
    }

    func startTranscription() {
        guard !isTranscribing else { return }

        guard let selectedFileURL else {
            errorMessage = "Please choose a file first."
            statusMessage = "No file selected."
            return
        }

        let mode = selectedMode
        let localModel = effectiveLocalModel
        let apiModel = effectiveAPIModel
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiBaseURLOverrideValue = apiBaseURLOverride.trimmedOrNil
        let languageCode = selectedLanguage.code
        let outputStyle = outputStyle
        let diarization = localDiarizationOptions
        let streamingEnabled = enableStreamingTranscript

        if mode == .api, apiKey.isEmpty {
            errorMessage = "API key is required in API mode."
            statusMessage = "Missing API key."
            return
        }

        if mode == .local,
           !expectedSpeakerCount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           parsedSpeakerCount == nil {
            errorMessage = "Expected speakers must be a positive number."
            statusMessage = "Invalid speaker count."
            return
        }

        stopAPIRamp()
        transcriptionTask?.cancel()
        shouldSavePartialOnStop = false
        isTranscribing = true
        selectedHistoryID = nil
        transcript = ""
        errorMessage = nil
        statusMessage = mode == .local ? "Checking local runtime..." : "Preparing media..."
        progress = mode == .local ? 0.02 : 0.03

        if mode == .local, enableSpeakerDiarization, !diarization.isEnabled {
            statusMessage = "Speaker separation requested, but token is missing. Continuing without it."
        }

        transcriptionTask = Task { [weak self] in
            guard let self else { return }

            do {
                let rawTranscript = try await Task.detached(priority: .userInitiated) { () async throws -> String in
                    switch mode {
                    case .local:
                        await MainActor.run {
                            self.statusMessage = "Checking local runtime..."
                            self.progress = max(self.progress, 0.08)
                        }
                        try LocalRuntimeBootstrapper().ensureWhisperReady()

                        await MainActor.run {
                            self.statusMessage = "Preparing media..."
                            self.progress = max(self.progress, 0.14)
                        }

                        let preparation = try MediaPreparationService().prepare(fileURL: selectedFileURL)
                        defer { preparation.cleanup() }

                        await MainActor.run {
                            self.statusMessage = "Running local transcription..."
                            self.progress = max(self.progress, 0.24)
                        }

                        let progressCallback: (@Sendable (Double) -> Void)? = { [weak self] fraction in
                            Task { @MainActor in
                                self?.applyLocalProgress(fraction)
                            }
                        }

                        let partialCallback: (@Sendable (String) -> Void)?
                        if streamingEnabled {
                            partialCallback = { [weak self] partial in
                                Task { @MainActor in
                                    self?.applyPartialTranscript(partial, style: outputStyle)
                                }
                            }
                        } else {
                            partialCallback = nil
                        }

                        return try LocalWhisperService().transcribe(
                            fileURL: preparation.fileURL,
                            model: localModel,
                            languageCode: languageCode,
                            diarization: diarization,
                            enableStreaming: streamingEnabled,
                            progress: progressCallback,
                            partialTranscript: partialCallback,
                            isCancelled: {
                                Task.isCancelled
                            }
                        )
                    case .api:
                        let preparation = try MediaPreparationService().prepare(fileURL: selectedFileURL)
                        defer { preparation.cleanup() }

                        await MainActor.run {
                            self.statusMessage = "Uploading media..."
                            self.progress = max(self.progress, 0.15)
                            self.startAPIRamp()
                        }

                        defer {
                            Task { @MainActor in
                                self.stopAPIRamp()
                            }
                        }

                        return try await OpenAITranscriptionService().transcribe(
                            fileURL: preparation.fileURL,
                            apiKey: apiKey,
                            model: apiModel,
                            languageCode: languageCode,
                            apiBaseURLOverride: apiBaseURLOverrideValue
                        )
                    }
                }.value

                guard !Task.isCancelled else {
                    throw TranscriptionError.cancelled("Transcription stopped.")
                }

                statusMessage = "Formatting transcript..."
                progress = max(progress, 0.94)
                let formattedTranscript = OutputFormatter.apply(style: outputStyle, to: rawTranscript)
                transcript = formattedTranscript
                addHistoryItem(content: formattedTranscript, isPartial: false)
                statusMessage = "Transcription complete."
                progress = 1
            } catch {
                handleRunError(error)
            }

            stopAPIRamp()
            isTranscribing = false
            transcriptionTask = nil
        }
    }

    func stopTranscription(savePartial: Bool) {
        guard isTranscribing else { return }

        shouldSavePartialOnStop = savePartial
        statusMessage = "Stopping transcription..."
        transcriptionTask?.cancel()
        stopAPIRamp()
    }

    func forceStopForQuit() {
        shouldSavePartialOnStop = false
        transcriptionTask?.cancel()
        stopAPIRamp()
    }

    func exportDOCX() {
        let exportText = activeDisplayTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !exportText.isEmpty else {
            errorMessage = "No transcript available to export."
            return
        }

        exportDOCX(transcriptText: exportText, suggestedBaseName: suggestedExportBaseName)
    }

    func exportLiveDOCX() {
        let exportText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !exportText.isEmpty else {
            errorMessage = "No transcript available to export."
            return
        }

        exportDOCX(transcriptText: exportText, suggestedBaseName: suggestedExportBaseName)
    }

    func exportSelectedHistoryDOCX() {
        guard let item = selectedHistoryItem else {
            errorMessage = "Select a history item to export."
            return
        }

        let exportText = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !exportText.isEmpty else {
            errorMessage = "Selected transcript is empty."
            return
        }

        exportDOCX(transcriptText: exportText, suggestedBaseName: sanitizedFileNameBase(item.title))
    }

    private func exportDOCX(transcriptText: String, suggestedBaseName: String) {
        let exportText = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !exportText.isEmpty else {
            errorMessage = "No transcript available to export."
            return
        }

        let filename = "\(suggestedBaseName).docx"
        statusMessage = "Building DOCX..."
        errorMessage = nil

        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try ExportService.makeDOCXData(transcript: exportText)
                }.value
                try ExportService.save(data: data, suggestedFileName: filename, allowedExtensions: ["docx"])
                statusMessage = "DOCX exported."
            } catch ExportError.cancelled {
                statusMessage = "Export cancelled."
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                errorMessage = message
                statusMessage = "DOCX export failed."
            }
        }
    }

    func exportPDF() {
        let exportText = activeDisplayTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !exportText.isEmpty else {
            errorMessage = "No transcript available to export."
            return
        }

        exportPDF(transcriptText: exportText, suggestedBaseName: suggestedExportBaseName)
    }

    func exportLivePDF() {
        let exportText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !exportText.isEmpty else {
            errorMessage = "No transcript available to export."
            return
        }

        exportPDF(transcriptText: exportText, suggestedBaseName: suggestedExportBaseName)
    }

    func exportSelectedHistoryPDF() {
        guard let item = selectedHistoryItem else {
            errorMessage = "Select a history item to export."
            return
        }

        let exportText = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !exportText.isEmpty else {
            errorMessage = "Selected transcript is empty."
            return
        }

        exportPDF(transcriptText: exportText, suggestedBaseName: sanitizedFileNameBase(item.title))
    }

    private func exportPDF(transcriptText: String, suggestedBaseName: String) {
        let exportText = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !exportText.isEmpty else {
            errorMessage = "No transcript available to export."
            return
        }

        do {
            let data = try ExportService.makePDFData(transcript: exportText)
            try ExportService.save(data: data, suggestedFileName: "\(suggestedBaseName).pdf", allowedExtensions: ["pdf"])
            statusMessage = "PDF exported."
            errorMessage = nil
        } catch ExportError.cancelled {
            statusMessage = "Export cancelled."
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = message
            statusMessage = "PDF export failed."
        }
    }

    private func applyLocalProgress(_ fraction: Double) {
        let clamped = max(0, min(1, fraction))
        let staged = 0.24 + (clamped * 0.68)
        if staged > progress {
            progress = staged
        }

        statusMessage = "Transcribing... \(Int((clamped * 100).rounded()))%"
    }

    private func applyPartialTranscript(_ partial: String, style: OutputStyle) {
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        transcript = OutputFormatter.apply(style: style, to: trimmed)
    }

    private func handleRunError(_ error: Error) {
        if error is CancellationError || (error as? TranscriptionError).map(isCancellationError) == true {
            if shouldSavePartialOnStop,
               let partial = transcript.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                addHistoryItem(content: partial, isPartial: true)
                statusMessage = "Transcription stopped. Partial saved."
            } else {
                statusMessage = "Transcription stopped."
            }

            errorMessage = nil
            progress = 0
            return
        }

        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        errorMessage = message
        statusMessage = "Transcription failed."
        progress = 0
    }

    private func addHistoryItem(content: String, isPartial: Bool) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let titleBase: String
        if selectedFileName == "No file selected" {
            titleBase = "Transcript"
        } else {
            titleBase = URL(fileURLWithPath: selectedFileName).deletingPathExtension().lastPathComponent
        }

        let suffix = isPartial ? " · Partial" : ""
        let title = "\(titleBase)\(suffix) · \(Self.historyTitleDateFormatter.string(from: Date()))"

        let item = TranscriptHistoryItem(
            title: title,
            createdAt: Date(),
            updatedAt: Date(),
            content: trimmed,
            isPartial: isPartial
        )

        historyItems.insert(item, at: 0)
        selectedHistoryID = item.id
        sortAndPersistHistory()
    }

    private func sortAndPersistHistory() {
        historyItems.sort { $0.updatedAt > $1.updatedAt }
        historyStore.save(historyItems)
    }

    private func startAPIRamp() {
        apiProgressTask?.cancel()
        apiProgressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let self else { return }
                guard self.isTranscribing else { continue }

                let nextIncrement: Double = self.progress < 0.35 ? 0.02 : 0.01
                if self.progress < 0.88 {
                    self.progress = min(0.88, self.progress + nextIncrement)
                }
            }
        }
    }

    private func stopAPIRamp() {
        apiProgressTask?.cancel()
        apiProgressTask = nil
    }

    private var parsedSpeakerCount: Int? {
        guard let value = Int(expectedSpeakerCount.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0
        else {
            return nil
        }
        return value
    }

    private var parsedChunkDurationSeconds: Int? {
        guard let value = Int(localChunkDurationSeconds.trimmingCharacters(in: .whitespacesAndNewlines)),
              (15...360).contains(value)
        else {
            return nil
        }
        return value
    }

    private var effectiveLocalChunkDurationSeconds: Int {
        parsedChunkDurationSeconds ?? LocalDiarizationOptions.defaultChunkDurationSeconds
    }

    private func makeLocalCopy(of url: URL) throws -> URL {
        let accessStarted = url.startAccessingSecurityScopedResource()
        defer {
            if accessStarted {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let localFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscribeMacApp-Input", isDirectory: true)
        try FileManager.default.createDirectory(at: localFolder, withIntermediateDirectories: true)

        let ext = url.pathExtension
        let destination = localFolder.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    private func isCancellationError(_ error: TranscriptionError) -> Bool {
        if case .cancelled = error {
            return true
        }
        return false
    }

    private func sanitizedFileNameBase(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars).replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "transcript" : trimmed
    }

    private static let historyTitleDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

private extension String {
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

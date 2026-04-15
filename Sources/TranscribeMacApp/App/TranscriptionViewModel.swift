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
    @Published var enableSpeakerDiarization: Bool = false
    @Published var enableStreamingTranscript: Bool = true
    @Published var expectedSpeakerCount: String = ""
    @Published var localChunkDurationSeconds: String = "\(LocalDiarizationOptions.defaultChunkDurationSeconds)"
    @Published var selectedLanguage: WhisperLanguage = .auto
    @Published var outputStyle: OutputStyle = .original
    @Published var transcript: String = ""
    @Published var isTranscribing: Bool = false
    @Published var isStoppingTranscription: Bool = false
    @Published var progress: Double = 0
    @Published var statusMessage: String = "Pick an audio or video file to begin."
    @Published var errorMessage: String?
    @Published var historyItems: [TranscriptHistoryItem] = []
    @Published var selectedHistoryID: UUID?
    @Published var diarizationSetupToken: String = ""
    @Published private(set) var diarizationSetupStatus: DiarizationSetupStatus = .notInstalled
    @Published private(set) var diarizationSetupStateText: String = "Not installed"

    let detectedRAMGB: Double
    let recommendedProfile: WhisperProfile

    private let historyStore = TranscriptHistoryStore()
    private let diarizationSetupStore = DiarizationSetupStore()
    private var copiedInputURL: URL?
    private var apiProgressTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var diarizationSetupTask: Task<Void, Never>?
    private var shouldSavePartialOnStop: Bool = false
    private var activeSessionID: UUID?
    private var diarizationSetupState: DiarizationSetupState = .notInstalled

    init() {
        let ram = RAMAdvisor.detectPhysicalRAMGB()
        detectedRAMGB = ram
        recommendedProfile = RAMAdvisor.recommendedProfile(forRAMGB: ram)
        selectedProfile = recommendedProfile

        historyItems = historyStore.load()
        selectedHistoryID = nil

        diarizationSetupState = diarizationSetupStore.load()
        diarizationSetupToken = diarizationSetupState.token
        diarizationSetupStatus = diarizationSetupState.status
        diarizationSetupStateText = setupStateText(from: diarizationSetupState)

        if !diarizationSetupState.isReady {
            enableSpeakerDiarization = false
        }
    }

    deinit {
        apiProgressTask?.cancel()
        transcriptionTask?.cancel()
        diarizationSetupTask?.cancel()
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
        if let selectedHistoryItem {
            return sanitizedFileNameBase(selectedHistoryItem.title)
        }
        return selectedFileURL?.deletingPathExtension().lastPathComponent ?? "transcript"
    }

    var selectedHistoryItem: TranscriptHistoryItem? {
        guard let selectedHistoryID else { return nil }
        return historyItems.first { $0.id == selectedHistoryID }
    }

    var activeDisplayTranscript: String {
        selectedHistoryItem?.content ?? ""
    }

    var mediaInputDisplayName: String {
        selectedHistoryItem?.sourceFileName ?? selectedFileName
    }

    var isDiarizationReady: Bool {
        diarizationSetupState.isReady
    }

    var isDiarizationSetupRunning: Bool {
        diarizationSetupStatus == .installing
    }

    var localDiarizationOptions: LocalDiarizationOptions {
        let token = diarizationRuntimeToken
        return LocalDiarizationOptions(
            isEnabled: enableSpeakerDiarization && isDiarizationReady && token != nil,
            huggingFaceToken: token,
            expectedSpeakerCount: parsedSpeakerCount,
            chunkDurationSeconds: effectiveLocalChunkDurationSeconds
        )
    }

    var currentSettingsSummary: String {
        switch selectedMode {
        case .local:
            let diarization: String
            if !isDiarizationReady {
                diarization = "Speaker Separation Setup Needed"
            } else {
                diarization = enableSpeakerDiarization ? "Speaker Separation On" : "Speaker Separation Off"
            }
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
            if !isTranscribing {
                progress = 0
            }
        } catch {
            errorMessage = "Could not import file: \(error.localizedDescription)"
            statusMessage = "Import failed."
            if !isTranscribing {
                progress = 0
            }
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
        errorMessage = nil

        if !isTranscribing {
            progress = 0
            statusMessage = "Pick an audio or video file to begin."
        }
    }

    func startNewChat() {
        selectedHistoryID = nil
        transcript = ""
        errorMessage = nil

        guard !isTranscribing else {
            statusMessage = isStoppingTranscription
                ? "Stopping transcription in background..."
                : "Transcription running in background..."
            return
        }

        activeSessionID = nil
        progress = 0

        if let selectedFileURL {
            statusMessage = "File ready: \(selectedFileURL.lastPathComponent)"
        } else {
            statusMessage = "Pick an audio or video file to begin."
        }
    }

    func selectHistoryItem(_ id: UUID) {
        guard historyItems.contains(where: { $0.id == id }) else {
            return
        }

        selectedHistoryID = id
        errorMessage = nil
        if !isTranscribing {
            progress = 0
            statusMessage = "Showing selected session."
        }
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
        if id == activeSessionID, isTranscribing {
            errorMessage = "Stop the active transcription before deleting this session."
            return
        }

        historyItems.removeAll { $0.id == id }
        if selectedHistoryID == id {
            selectedHistoryID = historyItems.first?.id
        }

        if activeSessionID == id {
            activeSessionID = nil
        }

        sortAndPersistHistory()
    }

    func installDiarizationModels() {
        guard !isDiarizationSetupRunning else { return }

        let token = diarizationSetupToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            persistDiarizationSetupState(
                status: .failed,
                token: "",
                message: "Enter a Hugging Face token to install diarization models."
            )
            errorMessage = "Hugging Face token is required."
            statusMessage = "Diarization setup failed."
            return
        }

        errorMessage = nil
        statusMessage = "Installing diarization prerequisites..."
        persistDiarizationSetupState(
            status: .installing,
            token: token,
            message: "Installing whisperx and verifying token access..."
        )

        diarizationSetupTask?.cancel()
        diarizationSetupTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await Task.detached(priority: .userInitiated) {
                    try DiarizationSetupService().installAndVerify(huggingFaceToken: token)
                }.value

                guard !Task.isCancelled else { return }

                persistDiarizationSetupState(
                    status: .ready,
                    token: token,
                    message: "whisperx + diarization prerequisites are installed and verified."
                )
                statusMessage = "Diarization models ready."
            } catch is CancellationError {
                persistDiarizationSetupState(
                    status: .failed,
                    token: token,
                    message: "Diarization setup was cancelled."
                )
                statusMessage = "Diarization setup cancelled."
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                persistDiarizationSetupState(
                    status: .failed,
                    token: token,
                    message: message
                )
                errorMessage = message
                statusMessage = "Diarization setup failed."
            }

            diarizationSetupTask = nil
        }
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
           enableSpeakerDiarization,
           !expectedSpeakerCount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           parsedSpeakerCount == nil {
            errorMessage = "Expected speakers must be a positive number."
            statusMessage = "Invalid speaker count."
            return
        }

        if mode == .local, enableSpeakerDiarization, !isDiarizationReady {
            errorMessage = "Install diarization models from Settings before enabling speaker separation."
            statusMessage = "Diarization setup required."
            return
        }

        stopAPIRamp()
        transcriptionTask?.cancel()
        shouldSavePartialOnStop = false
        isStoppingTranscription = false
        transcript = ""
        errorMessage = nil

        let sessionFileName = selectedFileName == "No file selected" ? selectedFileURL.lastPathComponent : selectedFileName
        let sessionID = createHistorySession(sourceFileName: sessionFileName)
        activeSessionID = sessionID
        selectedHistoryID = sessionID

        isTranscribing = true
        statusMessage = mode == .local ? "Checking local runtime..." : "Preparing media..."
        progress = mode == .local ? 0.02 : 0.03

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
                                    self?.applyPartialTranscript(partial, style: outputStyle, sessionID: sessionID)
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
                updateHistorySession(
                    id: sessionID,
                    content: formattedTranscript,
                    status: .completed,
                    failureMessage: nil,
                    clearFailureMessage: true,
                    keepExistingContentWhenEmpty: false
                )
                statusMessage = "Transcription complete."
                progress = 1
            } catch {
                handleRunError(error, sessionID: sessionID)
            }

            stopAPIRamp()
            isTranscribing = false
            isStoppingTranscription = false
            transcriptionTask = nil
            activeSessionID = nil
            shouldSavePartialOnStop = false
        }
    }

    func stopTranscription(savePartial: Bool) {
        guard isTranscribing, !isStoppingTranscription else { return }

        shouldSavePartialOnStop = savePartial
        isStoppingTranscription = true
        statusMessage = "Stopping transcription..."
        transcriptionTask?.cancel()
        stopAPIRamp()
    }

    func forceStopForQuit() {
        shouldSavePartialOnStop = false
        isStoppingTranscription = true
        if let activeSessionID {
            updateHistorySession(
                id: activeSessionID,
                content: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                status: .cancelled,
                failureMessage: nil,
                clearFailureMessage: true,
                keepExistingContentWhenEmpty: true
            )
        }
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
        exportDOCX()
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
        exportPDF()
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

    private func applyPartialTranscript(_ partial: String, style: OutputStyle, sessionID: UUID) {
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let formatted = OutputFormatter.apply(style: style, to: trimmed)
        transcript = formatted
        updateHistorySession(
            id: sessionID,
            content: formatted,
            status: .running,
            failureMessage: nil,
            clearFailureMessage: true
        )
    }

    private func handleRunError(_ error: Error, sessionID: UUID) {
        if error is CancellationError || (error as? TranscriptionError).map(isCancellationError) == true {
            let trimmedPartial = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            let shouldKeepMessage = shouldSavePartialOnStop && !trimmedPartial.isEmpty

            updateHistorySession(
                id: sessionID,
                content: trimmedPartial,
                status: .cancelled,
                failureMessage: nil,
                clearFailureMessage: true,
                keepExistingContentWhenEmpty: true
            )

            statusMessage = shouldKeepMessage ? "Transcription stopped. Partial saved." : "Transcription stopped."
            errorMessage = nil
            progress = 0
            return
        }

        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        errorMessage = message
        statusMessage = "Transcription failed."
        progress = 0
        let partial = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        updateHistorySession(
            id: sessionID,
            content: partial,
            status: .failed,
            failureMessage: message,
            clearFailureMessage: false,
            keepExistingContentWhenEmpty: true
        )
    }

    private func createHistorySession(sourceFileName: String) -> UUID {
        let resolvedSource = sourceFileName.trimmedOrNil ?? "No file selected"
        let titleBase: String
        if resolvedSource == "No file selected" {
            titleBase = "Transcript"
        } else {
            titleBase = URL(fileURLWithPath: resolvedSource).deletingPathExtension().lastPathComponent
        }

        let now = Date()
        let title = "\(titleBase) · \(Self.historyTitleDateFormatter.string(from: now))"

        let item = TranscriptHistoryItem(
            title: title,
            createdAt: now,
            updatedAt: now,
            content: "",
            isPartial: true,
            sessionStatus: .running,
            sourceFileName: resolvedSource,
            failureMessage: nil
        )

        historyItems.insert(item, at: 0)
        selectedHistoryID = item.id
        sortAndPersistHistory()
        return item.id
    }

    private func updateHistorySession(
        id: UUID,
        content: String? = nil,
        status: TranscriptSessionStatus? = nil,
        failureMessage: String? = nil,
        clearFailureMessage: Bool = false,
        keepExistingContentWhenEmpty: Bool = true
    ) {
        guard let idx = historyItems.firstIndex(where: { $0.id == id }) else {
            return
        }

        if let content {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty || !keepExistingContentWhenEmpty {
                historyItems[idx].content = trimmed
            }
        }

        if let status {
            historyItems[idx].sessionStatus = status
            historyItems[idx].isPartial = (status != .completed)
        }

        if clearFailureMessage {
            historyItems[idx].failureMessage = nil
        } else if let failureMessage {
            historyItems[idx].failureMessage = failureMessage
        }

        historyItems[idx].updatedAt = Date()
        sortAndPersistHistory()
    }

    private func sortAndPersistHistory() {
        historyItems.sort { $0.updatedAt > $1.updatedAt }

        if let selectedHistoryID,
                  !historyItems.contains(where: { $0.id == selectedHistoryID }) {
            self.selectedHistoryID = historyItems.first?.id
        }

        historyStore.save(historyItems)
    }

    private func persistDiarizationSetupState(status: DiarizationSetupStatus, token: String, message: String?) {
        let state = DiarizationSetupState(
            status: status,
            token: token,
            message: message,
            updatedAt: Date()
        )

        diarizationSetupState = state
        diarizationSetupStatus = state.status
        diarizationSetupToken = token
        diarizationSetupStateText = setupStateText(from: state)
        diarizationSetupStore.save(state)

        if !state.isReady {
            enableSpeakerDiarization = false
        }
    }

    private func setupStateText(from state: DiarizationSetupState) -> String {
        let base: String
        switch state.status {
        case .notInstalled:
            base = "Not installed"
        case .installing:
            base = "Installing"
        case .ready:
            base = "Ready"
        case .failed:
            base = "Failed"
        }

        if let message = state.message?.trimmedOrNil {
            return "\(base): \(message)"
        }

        return base
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

    private var diarizationRuntimeToken: String? {
        guard diarizationSetupState.isReady else { return nil }
        return diarizationSetupState.token.trimmedOrNil
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

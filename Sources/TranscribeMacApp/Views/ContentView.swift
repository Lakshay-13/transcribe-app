import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var viewModel: TranscriptionViewModel
    @State private var isImporterPresented = false
    @State private var isDropTargeted = false
    @State private var animateBackdrop = false
    @State private var renameTargetID: UUID?
    @State private var renameDraft: String = ""
    @State private var isRenameSheetPresented = false
    @State private var isHistorySidebarVisible = false

    var body: some View {
        ZStack {
            atmosphereBackground

            workspaceLayout
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) {
                animateBackdrop = true
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        isHistorySidebarVisible.toggle()
                    }
                } label: {
                    Label("Toggle History", systemImage: "sidebar.leading")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 30, height: 24, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isHistorySidebarVisible ? "Hide History" : "Show History")
            }

        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first {
                    viewModel.selectFile(url: url)
                }
            case let .failure(error):
                viewModel.setImporterError(error)
            }
        }
        .sheet(isPresented: $isRenameSheetPresented) {
            renameSheet
        }
    }

    private var workspaceLayout: some View {
        GeometryReader { proxy in
            let totalWidth = max(proxy.size.width, 1)
            let metrics = computedWorkspaceMetrics(totalWidth: totalWidth)

            HStack(spacing: 0) {
                if isHistorySidebarVisible {
                    historySidebar(width: metrics.sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))

                    Divider()
                        .overlay(Color.white.opacity(0.10))
                }

                mainPageContent(
                    maxContentWidth: metrics.mainContentMaxWidth,
                    horizontalInset: metrics.mainHorizontalInset
                )
                .frame(width: metrics.mainPaneWidth, alignment: .top)
            }
            .animation(.easeInOut(duration: 0.22), value: isHistorySidebarVisible)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func mainPageContent(maxContentWidth: CGFloat, horizontalInset: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                inputCard
                actionCard
                progressSection

                if hasActiveTranscriptContent {
                    transcriptCard
                }

                if hasActiveTranscriptContent {
                    activeExportRow
                }

                settingsSummaryFooter
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: maxContentWidth)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, horizontalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var atmosphereBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black,
                    Color(red: 0.10, green: 0.10, blue: 0.11),
                    Color(red: 0.06, green: 0.06, blue: 0.07)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 420, height: 420)
                .blur(radius: 56)
                .offset(x: animateBackdrop ? -200 : -140, y: -210)

            Circle()
                .fill(Color.white.opacity(0.05))
                .frame(width: 540, height: 540)
                .blur(radius: 66)
                .offset(x: animateBackdrop ? 240 : 190, y: animateBackdrop ? 200 : 245)

            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.24)
        }
        .ignoresSafeArea()
    }

    private var inputCard: some View {
        GlassCard(title: "Media Input", subtitle: "Drag & drop audio/video, or choose a file") {
            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                isDropTargeted ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.30),
                                style: StrokeStyle(lineWidth: isDropTargeted ? 2.2 : 1.2, dash: [7, 6])
                            )
                    }
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: isDropTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(isDropTargeted ? .primary : .secondary)
                            Text("Drop file here")
                                .font(.headline)
                            Text(viewModel.selectedFileName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.12), in: Capsule())
                        }
                        .padding(12)
                    }
                    .frame(height: 132)
                    .animation(.easeInOut(duration: 0.2), value: isDropTargeted)
                    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop)

                HStack(spacing: 10) {
                    Button("Choose File") {
                        isImporterPresented = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(viewModel.isTranscribing)

                    Button("Clear") {
                        viewModel.clearSelection()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(viewModel.selectedFileURL == nil || viewModel.isTranscribing)

                    Spacer()
                }
            }
        }
    }

    private var actionCard: some View {
        GlassCard(title: "Transcribe") {
            HStack(spacing: 12) {
                Button {
                    viewModel.startTranscription()
                } label: {
                    Label(viewModel.isTranscribing ? "Running..." : "Start Transcription", systemImage: "waveform")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.selectedFileURL == nil || viewModel.isTranscribing)

                if viewModel.isTranscribing {
                    Button("Stop & Save Partial") {
                        viewModel.stopTranscription(savePartial: true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button("Stop") {
                        viewModel.stopTranscription(savePartial: false)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                Spacer()
            }
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        if viewModel.isTranscribing || viewModel.progress > 0 || viewModel.errorMessage != nil {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: viewModel.progress)
                    .progressViewStyle(.linear)
                    .tint(Color.white.opacity(0.9))

                Text(viewModel.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private var transcriptCard: some View {
        GlassCard(title: "Transcript", subtitle: transcriptSubtitle) {
            VStack(alignment: .leading, spacing: 12) {
                if let item = viewModel.selectedHistoryItem {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.headline)
                                .lineLimit(2)
                            Text(Self.historyDateFormatter.string(from: item.updatedAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Show Live") {
                            clearHistorySelection()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(activeTranscriptMessages.enumerated()), id: \.offset) { _, message in
                            transcriptRow(message: message)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 280)
            }
        }
    }

    private func historySidebar(width: CGFloat) -> some View {
        Group {
            if viewModel.historyItems.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("No saved transcripts yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List(selection: historySelectionBinding) {
                    ForEach(viewModel.historyItems) { item in
                        historyThreadRow(item)
                            .tag(item.id)
                            .contextMenu {
                                Button("Rename") {
                                    presentRename(for: item)
                                }
                                Button("Delete", role: .destructive) {
                                    viewModel.deleteHistoryItem(item.id)
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }
        }
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.08), Color.white.opacity(0.04)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func historyThreadRow(_ item: TranscriptHistoryItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(item.isPartial ? Color.orange.opacity(0.9) : Color.white.opacity(0.72))
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    Text(historyRelativeFormatter.localizedString(for: item.updatedAt, relativeTo: Date()))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(historySnippet(from: item.content))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private func transcriptRow(message: String) -> some View {
        let parsed = splitSpeakerPrefix(message)

        return VStack(alignment: .leading, spacing: 6) {
            if let speaker = parsed.speaker {
                Text(speaker)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(parsed.body)
                .font(.body)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var liveExportRow: some View {
        HStack(spacing: 12) {
            Button("Export DOCX") {
                viewModel.exportLiveDOCX()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!hasLiveTranscript)

            Button("Export PDF") {
                viewModel.exportLivePDF()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!hasLiveTranscript)

            Spacer()
        }
        .padding(.horizontal, 2)
    }

    private var activeExportRow: some View {
        Group {
            if viewModel.selectedHistoryItem != nil {
                historyExportRow
            } else {
                liveExportRow
            }
        }
    }

    private var historyExportRow: some View {
        HStack(spacing: 12) {
            Button("Export DOCX") {
                viewModel.exportSelectedHistoryDOCX()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!hasSelectedHistoryTranscript)

            Button("Export PDF") {
                viewModel.exportSelectedHistoryPDF()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!hasSelectedHistoryTranscript)

            Spacer()
        }
        .padding(.horizontal, 2)
    }

    private var settingsSummaryFooter: some View {
        HStack {
            Spacer()
            Text(viewModel.currentSettingsSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
        }
        .padding(.top, 2)
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Transcript")
                .font(.headline)

            TextField("Title", text: $renameDraft)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    isRenameSheetPresented = false
                    renameTargetID = nil
                }
                Button("Save") {
                    if let renameTargetID {
                        viewModel.renameHistoryItem(id: renameTargetID, to: renameDraft)
                    }
                    isRenameSheetPresented = false
                    self.renameTargetID = nil
                }
                .buttonStyle(.borderedProminent)
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var hasLiveTranscript: Bool {
        !viewModel.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasSelectedHistoryTranscript: Bool {
        guard let item = viewModel.selectedHistoryItem else { return false }
        return !item.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasActiveTranscriptContent: Bool {
        if viewModel.selectedHistoryItem != nil {
            return hasSelectedHistoryTranscript
        }
        return hasLiveTranscript
    }

    private var liveTranscriptMessages: [String] {
        messages(from: viewModel.transcript)
    }

    private var historyPreviewMessages: [String] {
        messages(from: viewModel.selectedHistoryItem?.content ?? "")
    }

    private var activeTranscriptMessages: [String] {
        viewModel.selectedHistoryItem == nil ? liveTranscriptMessages : historyPreviewMessages
    }

    private var transcriptSubtitle: String {
        if viewModel.selectedHistoryItem != nil {
            return "Saved"
        }
        return viewModel.isTranscribing ? "Live" : "Latest"
    }

    private var historySelectionBinding: Binding<UUID?> {
        Binding(
            get: { viewModel.selectedHistoryID },
            set: { newValue in
                if let id = newValue {
                    viewModel.selectHistoryItem(id)
                } else {
                    clearHistorySelection()
                }
            }
        )
    }

    private func presentRename(for item: TranscriptHistoryItem) {
        renameDraft = item.title
        renameTargetID = item.id
        isRenameSheetPresented = true
    }

    private func clearHistorySelection() {
        viewModel.selectedHistoryID = nil
        if hasLiveTranscript {
            viewModel.statusMessage = "Showing live transcript."
        }
    }

    private struct WorkspaceMetrics {
        let sidebarWidth: CGFloat
        let mainPaneWidth: CGFloat
        let mainHorizontalInset: CGFloat
        let mainContentMaxWidth: CGFloat
    }

    private func computedWorkspaceMetrics(totalWidth: CGFloat) -> WorkspaceMetrics {
        let sidebarWidth = isHistorySidebarVisible ? computedSidebarWidth(totalWidth: totalWidth) : 0
        let dividerWidth: CGFloat = sidebarWidth > 0 ? 1 : 0
        let mainPaneWidth = max(totalWidth - sidebarWidth - dividerWidth, 1)
        let mainHorizontalInset = computedMainHorizontalInset(
            mainPaneWidth: mainPaneWidth,
            sidebarVisible: isHistorySidebarVisible
        )
        let mainContentMaxWidth = computedMainContentMaxWidth(
            mainPaneWidth: mainPaneWidth,
            horizontalInset: mainHorizontalInset
        )

        return WorkspaceMetrics(
            sidebarWidth: sidebarWidth,
            mainPaneWidth: mainPaneWidth,
            mainHorizontalInset: mainHorizontalInset,
            mainContentMaxWidth: mainContentMaxWidth
        )
    }

    private func computedSidebarWidth(totalWidth: CGFloat) -> CGFloat {
        let targetWidth = totalWidth * 0.40
        let minSidebarWidth: CGFloat = 210
        let maxSidebarWidth: CGFloat = 340
        let minimumMainPaneWidth: CGFloat = 430
        let dividerWidth: CGFloat = 1
        let maxAllowedByMainPane = max(totalWidth - minimumMainPaneWidth - dividerWidth, minSidebarWidth)
        let hardCappedWidth = min(max(targetWidth, minSidebarWidth), maxSidebarWidth)
        return min(hardCappedWidth, maxAllowedByMainPane)
    }

    private func computedMainHorizontalInset(mainPaneWidth: CGFloat, sidebarVisible: Bool) -> CGFloat {
        let tieredInset: CGFloat
        if sidebarVisible {
            switch mainPaneWidth {
            case ..<760:
                tieredInset = 10
            case ..<980:
                tieredInset = 14
            case ..<1240:
                tieredInset = 22
            case ..<1680:
                tieredInset = 34
            default:
                tieredInset = 50
            }
        } else {
            switch mainPaneWidth {
            case ..<760:
                tieredInset = 12
            case ..<980:
                tieredInset = 18
            case ..<1240:
                tieredInset = 28
            case ..<1680:
                tieredInset = 44
            default:
                tieredInset = 64
            }
        }

        let maxInsetToPreserveUsableWidth = max((mainPaneWidth - 520) / 2, 8)
        return min(tieredInset, maxInsetToPreserveUsableWidth)
    }

    private func computedMainContentMaxWidth(mainPaneWidth: CGFloat, horizontalInset: CGFloat) -> CGFloat {
        let availableWidth = max(mainPaneWidth - (horizontalInset * 2), 1)

        switch mainPaneWidth {
        case ..<1280:
            return availableWidth
        case ..<1680:
            return min(availableWidth, 1040)
        default:
            return min(availableWidth, 1120)
        }
    }

    private func historySnippet(from text: String) -> String {
        let compact = text
            .replacingOccurrences(of: "\n\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.isEmpty ? "No text" : compact
    }

    private func messages(from transcript: String) -> [String] {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let blockSplit = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if blockSplit.count > 1 {
            return blockSplit
        }

        return text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func splitSpeakerPrefix(_ message: String) -> (speaker: String?, body: String) {
        let parts = message.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return (nil, message)
        }

        let speaker = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard speaker.lowercased().hasPrefix("speaker") else {
            return (nil, message)
        }

        let body = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (speaker, body)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let droppedURL: URL?

            if let data = item as? Data {
                droppedURL = NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL?
            } else if let url = item as? URL {
                droppedURL = url
            } else if let string = item as? String {
                droppedURL = URL(string: string)
            } else {
                droppedURL = nil
            }

            guard let droppedURL else { return }
            Task { @MainActor in
                viewModel.selectFile(url: droppedURL)
            }
        }

        return true
    }

    private static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private var historyRelativeFormatter: RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }
}

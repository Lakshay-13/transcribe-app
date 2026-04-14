import AppKit
import SwiftUI

@main
struct TranscribeMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = TranscriptionViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 780, minHeight: 620)
                .onAppear {
                    appDelegate.hasRunningTasks = { viewModel.isTranscribing }
                    appDelegate.prepareForQuit = { viewModel.forceStopForQuit() }
                }
        }

        Settings {
            SettingsView(viewModel: viewModel)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var hasRunningTasks: (() -> Bool)?
    var prepareForQuit: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppIconLoader.applyDockIcon()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard hasRunningTasks?() == true else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Transcribe?"
        alert.informativeText = "All running transcription tasks will end."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            prepareForQuit?()
            return .terminateNow
        }

        return .terminateCancel
    }
}

enum AppIconLoader {
    @MainActor
    static func applyDockIcon() {
        let fileManager = FileManager.default
        let iconCandidates: [URL?] = [
            Bundle.main.url(forResource: "logo_transcribe", withExtension: "png"),
            Bundle.module.url(forResource: "logo_transcribe", withExtension: "png"),
            URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent("logo_transcribe.png"),
            URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent("Sources/TranscribeMacApp/Resources/logo_transcribe.png")
        ]

        for candidate in iconCandidates.compactMap({ $0 }) {
            if let image = NSImage(contentsOf: candidate) {
                NSApplication.shared.applicationIconImage = image
                return
            }
        }
    }
}

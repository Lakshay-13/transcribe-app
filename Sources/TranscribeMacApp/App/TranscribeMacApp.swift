import AppKit
import SwiftUI

@main
struct TranscribeMacApp: App {
    static let transcriptionWindowID = "transcribe-window"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = TranscriptionViewModel()

    var body: some Scene {
        WindowGroup(id: Self.transcriptionWindowID) {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 780, minHeight: 620)
                .onAppear {
                    appDelegate.hasRunningTasks = { viewModel.isTranscribing }
                    appDelegate.prepareForQuit = { viewModel.forceStopForQuit() }
                }
        }
        .windowToolbarStyle(.unifiedCompact)

        Settings {
            SettingsView(viewModel: viewModel)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var hasRunningTasks: (() -> Bool)?
    var prepareForQuit: (() -> Void)?
    private var titlebarDoubleClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppIconLoader.applyDockIcon()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        installTitlebarDoubleClickZoomMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let titlebarDoubleClickMonitor {
            NSEvent.removeMonitor(titlebarDoubleClickMonitor)
            self.titlebarDoubleClickMonitor = nil
        }
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

    private func installTitlebarDoubleClickZoomMonitor() {
        guard titlebarDoubleClickMonitor == nil else { return }

        titlebarDoubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleTitlebarDoubleClick(event)
            return event
        }
    }

    private func handleTitlebarDoubleClick(_ event: NSEvent) {
        guard event.clickCount == 2,
              let window = event.window,
              shouldZoomWindow(for: event, in: window) else {
            return
        }

        window.performZoom(nil)
    }

    private func shouldZoomWindow(for event: NSEvent, in window: NSWindow) -> Bool {
        guard window.styleMask.contains(.resizable),
              window.standardWindowButton(.zoomButton)?.isEnabled == true,
              window.toolbar != nil else {
            return false
        }

        let locationInWindow = event.locationInWindow
        guard isPointInTitlebarRegion(locationInWindow, for: window),
              !isPointOnStandardWindowButton(locationInWindow, in: window),
              !isInteractiveToolbarHit(locationInWindow, in: window) else {
            return false
        }

        return true
    }

    private func isPointInTitlebarRegion(_ point: NSPoint, for window: NSWindow) -> Bool {
        point.y >= window.contentLayoutRect.maxY && point.y <= window.frame.height
    }

    private func isPointOnStandardWindowButton(_ point: NSPoint, in window: NSWindow) -> Bool {
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

        for buttonType in buttonTypes {
            guard let button = window.standardWindowButton(buttonType) else { continue }
            let buttonFrameInWindow = button.convert(button.bounds, to: nil).insetBy(dx: -4, dy: -4)
            if buttonFrameInWindow.contains(point) {
                return true
            }
        }

        return false
    }

    private func isInteractiveToolbarHit(_ point: NSPoint, in window: NSWindow) -> Bool {
        guard let frameView = window.contentView?.superview else { return false }
        let pointInFrameView = frameView.convert(point, from: nil)
        guard let hitView = frameView.hitTest(pointInFrameView) else { return false }
        return isInteractiveTitlebarView(hitView)
    }

    private func isInteractiveTitlebarView(_ view: NSView) -> Bool {
        var currentView: NSView? = view

        while let candidate = currentView {
            if candidate is NSControl || candidate is NSTextView || candidate is NSScrollView || candidate is NSScroller {
                return true
            }

            let className = NSStringFromClass(type(of: candidate))
            if className.contains("ToolbarItem") || className.contains("TitlebarAccessory") {
                return true
            }

            currentView = candidate.superview
        }

        return false
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

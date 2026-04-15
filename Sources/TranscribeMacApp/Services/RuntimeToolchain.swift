import Foundation

struct RuntimeToolchain: Sendable {
    static let ffmpegOverrideEnvironmentKey = "TRANSCIBE_FFMPEG_PATH"
    private static let defaultSystemPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    private static let systemManagedVenvDirectoryPath = "/Library/Application Support/Transcribe/venv"

    static var userManagedVenvDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Transcribe", isDirectory: true)
            .appendingPathComponent("venv", isDirectory: true)
    }

    static var systemManagedVenvDirectoryURL: URL {
        URL(fileURLWithPath: systemManagedVenvDirectoryPath, isDirectory: true)
    }

    static var userManagedPythonCandidatePaths: [String] {
        pythonCandidatePaths(in: userManagedVenvDirectoryURL)
    }

    static var systemManagedPythonCandidatePaths: [String] {
        pythonCandidatePaths(in: systemManagedVenvDirectoryURL)
    }

    static func userManagedPythonInvocation(fileManager: FileManager = .default) -> ProcessInvocation? {
        pythonInvocation(from: userManagedPythonCandidatePaths, fileManager: fileManager)
    }

    static func managedPythonInvocationCandidates(fileManager: FileManager = .default) -> [ProcessInvocation] {
        var candidates: [ProcessInvocation] = []

        if let userPython = userManagedPythonInvocation(fileManager: fileManager) {
            candidates.append(userPython)
        }

        if let systemPython = pythonInvocation(from: systemManagedPythonCandidatePaths, fileManager: fileManager) {
            candidates.append(systemPython)
        }

        return candidates
    }

    static func isManagedPythonInvocation(_ invocation: ProcessInvocation) -> Bool {
        invocation.argumentsPrefix.isEmpty && (
            userManagedPythonCandidatePaths.contains(invocation.executablePath) ||
                systemManagedPythonCandidatePaths.contains(invocation.executablePath)
        )
    }

    let ffmpegInvocation: ProcessInvocation
    let pythonInvocation: ProcessInvocation
    let environmentOverrides: [String: String]
    private let bundledFFmpegPathForDisplay: String

    init(
        processInfo: ProcessInfo = .processInfo,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) {
        let environment = processInfo.environment
        let bundledCandidatePath = Self.bundledFFmpegPath(for: bundle)
        bundledFFmpegPathForDisplay = bundledCandidatePath ?? "<App>.app/Contents/Resources/bin/ffmpeg"

        if let overridePath = Self.validExecutablePath(
            from: environment[Self.ffmpegOverrideEnvironmentKey],
            fileManager: fileManager
        ) {
            ffmpegInvocation = ProcessInvocation(executablePath: overridePath)
            pythonInvocation = Self.pythonInvocation(fileManager: fileManager)
            environmentOverrides = Self.pathEnvironmentOverride(
                ffmpegExecutablePath: overridePath,
                baseEnvironment: environment
            )
            return
        }

        if let bundledCandidatePath, fileManager.isExecutableFile(atPath: bundledCandidatePath) {
            ffmpegInvocation = ProcessInvocation(executablePath: bundledCandidatePath)
            pythonInvocation = Self.pythonInvocation(fileManager: fileManager)
            environmentOverrides = Self.pathEnvironmentOverride(
                ffmpegExecutablePath: bundledCandidatePath,
                baseEnvironment: environment
            )
            return
        }

        ffmpegInvocation = ProcessInvocation(executablePath: "/usr/bin/env", argumentsPrefix: ["ffmpeg"])
        pythonInvocation = Self.pythonInvocation(fileManager: fileManager)
        environmentOverrides = [:]
    }

    func ffmpegMissingMessage() -> String {
        """
        ffmpeg is not available. Checked \(Self.ffmpegOverrideEnvironmentKey), then bundled binary at \(bundledFFmpegPathForDisplay), then system PATH. Bundled ffmpeg was not found or not executable. Add ffmpeg at Contents/Resources/bin/ffmpeg in the app bundle, or install it on the system (for example: brew install ffmpeg).
        """
    }

    func ffmpegIsLikelyMissing(in output: ProcessOutput) -> Bool {
        let combined = "\(output.standardError)\n\(output.standardOutput)".lowercased()
        let patterns = [
            "/usr/bin/env: ffmpeg: no such file or directory",
            "env: ffmpeg: no such file or directory",
            "command not found: ffmpeg",
            "ffmpeg: command not found",
            "no such file or directory: 'ffmpeg'",
            "no such file or directory: \"ffmpeg\"",
            "file not found: 'ffmpeg'",
            "file not found: \"ffmpeg\"",
            "ffmpeg not found",
            "executable file not found in $path"
        ]

        return patterns.contains { combined.contains($0) }
    }
}

extension RuntimeToolchain {
    struct ProcessInvocation: Sendable {
        let executablePath: String
        let argumentsPrefix: [String]

        init(executablePath: String, argumentsPrefix: [String] = []) {
            self.executablePath = executablePath
            self.argumentsPrefix = argumentsPrefix
        }
    }
}

private extension RuntimeToolchain {
    static func pythonInvocation(fileManager: FileManager) -> ProcessInvocation {
        if let managedPython = managedPythonInvocationCandidates(fileManager: fileManager).first {
            return managedPython
        }

        return ProcessInvocation(executablePath: "/usr/bin/env", argumentsPrefix: ["python3"])
    }

    static func pythonInvocation(from candidatePaths: [String], fileManager: FileManager) -> ProcessInvocation? {
        for path in candidatePaths where fileManager.isExecutableFile(atPath: path) {
            return ProcessInvocation(executablePath: path)
        }
        return nil
    }

    static func pythonCandidatePaths(in venvDirectoryURL: URL) -> [String] {
        let binDirectoryURL = venvDirectoryURL.appendingPathComponent("bin", isDirectory: true)
        return [
            binDirectoryURL.appendingPathComponent("python3").path,
            binDirectoryURL.appendingPathComponent("python").path
        ]
    }

    static func validExecutablePath(from rawPath: String?, fileManager: FileManager) -> String? {
        guard let rawPath else { return nil }

        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }

        let expandedPath = (trimmedPath as NSString).expandingTildeInPath
        let standardizedPath = URL(fileURLWithPath: expandedPath).standardizedFileURL.path
        guard fileManager.isExecutableFile(atPath: standardizedPath) else { return nil }

        return standardizedPath
    }

    static func bundledFFmpegPath(for bundle: Bundle) -> String? {
        if bundle.bundleURL.pathExtension.lowercased() == "app" {
            return bundle.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("ffmpeg")
                .path
        }

        if let resourceURL = bundle.resourceURL {
            return resourceURL
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("ffmpeg")
                .path
        }

        if let executableURL = bundle.executableURL {
            return executableURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("ffmpeg")
                .path
        }

        return nil
    }

    static func pathEnvironmentOverride(
        ffmpegExecutablePath: String,
        baseEnvironment: [String: String]
    ) -> [String: String] {
        let ffmpegDirectory = URL(fileURLWithPath: ffmpegExecutablePath).deletingLastPathComponent().path
        guard !ffmpegDirectory.isEmpty else { return [:] }

        let currentPath = baseEnvironment["PATH"] ?? defaultSystemPath
        let remainingPathComponents = currentPath.colonSeparatedComponents.filter { $0 != ffmpegDirectory }

        let updatedPath = ([ffmpegDirectory] + remainingPathComponents).joined(separator: ":")
        let ffmpegLibDirectory = URL(fileURLWithPath: ffmpegDirectory)
            .deletingLastPathComponent()
            .appendingPathComponent("lib")
            .path

        var overrides = ["PATH": updatedPath]

        if !ffmpegLibDirectory.isEmpty {
            let currentDYLD = baseEnvironment["DYLD_LIBRARY_PATH"] ?? ""
            let dyldComponents = currentDYLD.colonSeparatedComponents.filter { $0 != ffmpegLibDirectory }
            overrides["DYLD_LIBRARY_PATH"] = ([ffmpegLibDirectory] + dyldComponents).joined(separator: ":")
        }

        return overrides
    }
}

private extension String {
    var colonSeparatedComponents: [String] {
        split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

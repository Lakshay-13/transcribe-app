import Foundation

struct LocalRuntimeBootstrapper: Sendable {
    private let runner = ProcessRunner()

    func ensureWhisperReady() throws {
        let fileManager = FileManager.default
        let runtimeToolchain = RuntimeToolchain(fileManager: fileManager)

        if whisperImportWorks(using: runtimeToolchain.pythonInvocation) {
            return
        }

        let userVenvURL = RuntimeToolchain.userManagedVenvDirectoryURL
        if RuntimeToolchain.userManagedPythonInvocation(fileManager: fileManager) == nil {
            try createUserManagedVenv(at: userVenvURL, seedPython: runtimeToolchain.pythonInvocation)
        }

        guard let userPython = RuntimeToolchain.userManagedPythonInvocation(fileManager: fileManager) else {
            throw TranscriptionError.validation(
                "Local runtime setup failed: managed Python was not found at \(userVenvURL.path). Delete that folder and retry."
            )
        }

        if whisperImportWorks(using: userPython) {
            return
        }

        try runChecked(
            invocation: userPython,
            arguments: ["-m", "pip", "install", "--upgrade", "pip"],
            environment: pipEnvironment,
            failureMessage: "Failed to update pip in managed runtime (\(userVenvURL.path)). Check internet access and retry."
        )

        try runChecked(
            invocation: userPython,
            arguments: ["-m", "pip", "install", "--upgrade", "openai-whisper"],
            environment: pipEnvironment,
            failureMessage: "Failed to install openai-whisper in managed runtime (\(userVenvURL.path)). Check internet access or package proxy settings and retry."
        )

        let verificationArguments = ["-c", "import whisper"]
        let verificationOutput = try run(
            invocation: userPython,
            arguments: verificationArguments,
            launchFailureMessage: "Could not launch managed Python to verify Whisper installation."
        )

        guard verificationOutput.exitCode == 0 else {
            throw TranscriptionError.commandFailed(
                command: commandDescription(for: userPython, arguments: verificationArguments),
                exitCode: verificationOutput.exitCode,
                message: "openai-whisper install completed but import still fails in \(userVenvURL.path). Delete that folder and retry. \(normalizedError(from: verificationOutput))"
            )
        }
    }
}

private extension LocalRuntimeBootstrapper {
    var pipEnvironment: [String: String] {
        [
            "PIP_DISABLE_PIP_VERSION_CHECK": "1",
            "PIP_NO_INPUT": "1"
        ]
    }

    func createUserManagedVenv(at venvURL: URL, seedPython: RuntimeToolchain.ProcessInvocation) throws {
        let parentDirectory = venvURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        } catch {
            throw TranscriptionError.fileOperation(
                "Could not create local runtime directory at \(parentDirectory.path): \(error.localizedDescription)"
            )
        }

        let creationArguments = ["-m", "venv", venvURL.path]
        let output = try run(
            invocation: seedPython,
            arguments: creationArguments,
            launchFailureMessage: "Python 3 is required for local runtime setup. Install python3 and retry."
        )

        guard output.exitCode == 0 else {
            throw TranscriptionError.commandFailed(
                command: commandDescription(for: seedPython, arguments: creationArguments),
                exitCode: output.exitCode,
                message: "Failed to create managed runtime at \(venvURL.path). Ensure Python 3 is available and writable. \(normalizedError(from: output))"
            )
        }
    }

    func whisperImportWorks(using invocation: RuntimeToolchain.ProcessInvocation) -> Bool {
        let arguments = invocation.argumentsPrefix + ["-c", "import whisper"]
        do {
            let output = try runner.run(executablePath: invocation.executablePath, arguments: arguments)
            return output.exitCode == 0
        } catch {
            return false
        }
    }

    func runChecked(
        invocation: RuntimeToolchain.ProcessInvocation,
        arguments: [String],
        environment: [String: String]? = nil,
        failureMessage: String
    ) throws {
        let output = try run(
            invocation: invocation,
            arguments: arguments,
            environment: environment,
            launchFailureMessage: failureMessage
        )

        guard output.exitCode == 0 else {
            throw TranscriptionError.commandFailed(
                command: commandDescription(for: invocation, arguments: arguments),
                exitCode: output.exitCode,
                message: "\(failureMessage) \(normalizedError(from: output))"
            )
        }
    }

    func run(
        invocation: RuntimeToolchain.ProcessInvocation,
        arguments: [String],
        environment: [String: String]? = nil,
        launchFailureMessage: String
    ) throws -> ProcessOutput {
        do {
            return try runner.run(
                executablePath: invocation.executablePath,
                arguments: invocation.argumentsPrefix + arguments,
                environment: environment
            )
        } catch let error as TranscriptionError {
            if case let .commandLaunchFailed(_, underlying) = error {
                throw TranscriptionError.validation("\(launchFailureMessage) \(underlying)")
            }
            throw error
        } catch {
            throw TranscriptionError.validation("\(launchFailureMessage) \(error.localizedDescription)")
        }
    }

    func commandDescription(for invocation: RuntimeToolchain.ProcessInvocation, arguments: [String]) -> String {
        ([shellEscapedToken(invocation.executablePath)]
            + invocation.argumentsPrefix.map(shellEscapedToken)
            + arguments.map(shellEscapedToken))
            .joined(separator: " ")
    }

    func shellEscapedToken(_ token: String) -> String {
        let requiresEscaping = token.contains { character in
            character == " " || character == "'" || character == "\""
        }

        guard requiresEscaping else {
            return token
        }

        let escaped = token.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    func normalizedError(from output: ProcessOutput) -> String {
        let stderr = output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty {
            return stderr
        }

        let stdout = output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty {
            return stdout
        }

        return "Unknown bootstrap error."
    }
}

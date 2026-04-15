import Foundation

enum DiarizationSetupStatus: String, Codable, Sendable {
    case notInstalled
    case installing
    case ready
    case failed
}

struct DiarizationSetupState: Codable, Sendable {
    var status: DiarizationSetupStatus
    var token: String
    var message: String?
    var updatedAt: Date

    var isReady: Bool {
        status == .ready && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static var notInstalled: Self {
        Self(status: .notInstalled, token: "", message: nil, updatedAt: Date())
    }
}

struct DiarizationSetupStore: Sendable {
    func load() -> DiarizationSetupState {
        guard let data = try? Data(contentsOf: storageURL) else {
            return .notInstalled
        }

        for decoder in decodeAttempts {
            if let decoded = try? decoder.decode(DiarizationSetupState.self, from: data) {
                return decoded
            }
        }

        return .notInstalled
    }

    func save(_ state: DiarizationSetupState) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)

            let folder = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            // Best-effort persistence only.
        }
    }

    private var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return appSupport
            .appendingPathComponent("TranscribeMacApp", isDirectory: true)
            .appendingPathComponent("diarization-setup.json")
    }

    private var decodeAttempts: [JSONDecoder] {
        let primary = JSONDecoder()
        primary.dateDecodingStrategy = .iso8601

        let fallback = JSONDecoder()
        fallback.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()

            if let isoString = try? container.decode(String.self),
               let parsed = Self.parseISO8601Date(isoString) {
                return parsed
            }

            if let numeric = try? container.decode(Double.self) {
                if numeric > 978_307_200 {
                    return Date(timeIntervalSince1970: numeric)
                }
                return Date(timeIntervalSinceReferenceDate: numeric)
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported date encoding for diarization setup state."
            )
        }

        return [primary, fallback, JSONDecoder()]
    }

    private static func parseISO8601Date(_ raw: String) -> Date? {
        let formatterWithFractional = ISO8601DateFormatter()
        formatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatterWithFractional.date(from: raw) {
            return value
        }
        return ISO8601DateFormatter().date(from: raw)
    }
}

struct DiarizationSetupService: Sendable {
    private let runner = ProcessRunner()

    func installAndVerify(huggingFaceToken: String) throws {
        let token = huggingFaceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw TranscriptionError.validation("Hugging Face token is required for diarization setup.")
        }

        try LocalRuntimeBootstrapper().ensureWhisperReady()

        let runtimeToolchain = RuntimeToolchain()
        let pythonInvocation = runtimeToolchain.pythonInvocation

        try runChecked(
            invocation: pythonInvocation,
            arguments: ["-m", "pip", "install", "--upgrade", "pip"],
            environment: pipEnvironment,
            failureMessage: "Failed to update pip for diarization setup."
        )

        try runChecked(
            invocation: pythonInvocation,
            arguments: ["-m", "pip", "install", "--upgrade", "whisperx", "pyannote.audio", "huggingface-hub"],
            environment: pipEnvironment,
            failureMessage: "Failed to install WhisperX diarization dependencies."
        )

        var verificationEnvironment = runtimeToolchain.environmentOverrides
        verificationEnvironment["HF_TOKEN"] = token
        verificationEnvironment["HF_HUB_DISABLE_TELEMETRY"] = "1"

        let verificationScript = """
import os
import whisperx
from pyannote.audio import Pipeline
from huggingface_hub import HfApi

token = os.environ.get("HF_TOKEN", "").strip()
if not token:
    raise RuntimeError("Missing Hugging Face token")

api = HfApi(token=token)
api.whoami()
api.model_info("pyannote/speaker-diarization-3.1", token=token)

_ = whisperx
_ = Pipeline
print("verified")
"""

        try runChecked(
            invocation: pythonInvocation,
            arguments: ["-c", verificationScript],
            environment: verificationEnvironment,
            failureMessage: "Diarization verification failed. Confirm token access to pyannote models on Hugging Face."
        )
    }
}

private extension DiarizationSetupService {
    var pipEnvironment: [String: String] {
        [
            "PIP_DISABLE_PIP_VERSION_CHECK": "1",
            "PIP_NO_INPUT": "1"
        ]
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

        return "Unknown diarization setup error."
    }
}
